//
//  OBDManager.swift
//  ID3Maps host app.
//
//  Reads the battery state of charge live from the car through a Bluetooth LE ELM327-type
//  OBD dongle (e.g. Vgate iCar Pro 2S) and hands it to the Intents extension via the shared
//  keychain. The cloud path (VW -> Smartcar -> Worker) is 2-5 minutes behind; this is ~5 s.
//
//  How it runs without the app being open: iOS keeps a pending connection to the remembered
//  dongle and relaunches the app (state restoration, background mode "bluetooth-central")
//  when the dongle powers up with the car.
//
//  What is NOT known for sure yet: the exact diagnostic request and scaling for the ID.3's
//  SoC. The default is the MEB battery controller (CAN 29-bit 17FC007B -> 17FE007B,
//  UDS 22 028C), with the scale chosen by comparing against the Smartcar SoC. "Run test"
//  tries several known requests and logs the raw answers so the right one can be picked.
//
//  Threading: all CoreBluetooth objects and state live on one private serial queue.
//

import Foundation
import CoreBluetooth

/// A decoded value shown in the app.
struct OBDDecoded: Sendable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// One raw battery value (identifier + payload hex) shown in the app until it is interpreted.
struct OBDExtra: Sendable, Identifiable {
    let did: String
    let hex: String
    var id: String { did }
}

final class OBDManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = OBDManager()

    // MARK: Public status (read from the UI)

    struct Status: Sendable {
        var state: String
        var device: String?
        var lastRaw: String?
        var lastSocPct: Double?
        var validated: Bool
        var calibration: String?
        var decoded: [OBDDecoded]
        // About the dongle
        var firmware: String?
        var volt12: String?
        var lastAnswer: Date?
        var okCount: Int
        var failCount: Int
        // Extra battery values (unverified identifiers: raw bytes for analysis)
        var extras: [OBDExtra]
        var scanProgress: String?
    }

    /// Asks the battery controller for ~180 data identifiers once and logs every positive answer,
    /// so the IDs for battery temperature, voltage, current etc. can be identified from the log.
    func runScan() { queue.async { self.startScanLocked() } }

    func status() -> Status { queue.sync { statusLocked() } }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            queue.async { newValue ? self.startLocked() : self.stopLocked() }
        }
    }

    func start() { queue.async { self.startLocked() } }

    /// CarPlay connected: skip any idle back-off and (re)arm the connection right away.
    func wake() {
        queue.async {
            self.idleBackoffUntil = .distantPast
            guard self.enabled else { return }
            if let p = self.peripheral, p.state != .connected { self.central?.connect(p) } else { self.startLocked() }
        }
    }

    /// Runs the list of candidate requests once and logs every raw answer.
    func runDiagnostics() { queue.async { self.diagnosticsPending = true; self.kickLocked() } }

    // MARK: Configuration

    private static let enabledKey = "obdEnabled"
    private static let deviceKey = "obdDeviceUUID"
    private static let restoreId = "id3maps.obd"
    /// GATT services used by Vgate / vLinker / generic BLE ELM327 dongles.
    private static var serviceUUIDs: [CBUUID] { [
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0"),
    ] }
    private static let nameHints = ["icar", "vgate", "vlink", "obd", "v-link", "ios-vlink", "elm"]

    /// Default poll: MEB battery controller over CAN 29-bit, UDS ReadDataByIdentifier 0x028C.
    private static let setup = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH1", "ATSP7", "ATSH17FC007B", "ATCRA17FE007B", "ATST96"]
    private static let pollCommand = "22028C"
    /// Unverified MEB battery-controller identifiers polled now and then (raw shown in the app).
    /// Rotating extra reads: HV voltage, current, 16 temperature sensors, plus a few still unknown.
    private static let extraDIDs = ["1E3B", "1E3D"] + tempDIDs + ["1E0E", "2A0B", "1E36", "1E38"]
    private static let pollMarker = "62028C"
    /// Candidate scalings of the single data byte (percent = byte / divisor).

    /// Diagnostic candidates: (label, setup commands, request).
    private static let candidates: [(String, [String], String)] = [
        ("BMS 29-bit 028C", ["ATSP7", "ATSH17FC007B", "ATCRA17FE007B"], "22028C"),
        ("BMS 29-bit F45B", ["ATSP7", "ATSH17FC007B", "ATCRA17FE007B"], "22F45B"),
        ("BMS 29-bit 1E0E", ["ATSP7", "ATSH17FC007B", "ATCRA17FE007B"], "221E0E"),
        ("BMS 11-bit 7E5 028C", ["ATSP6", "ATSH7E5", "ATCRA7ED"], "22028C"),
        ("BMS 11-bit 7E5 F45B", ["ATSP6", "ATSH7E5", "ATCRA7ED"], "22F45B"),
        ("Gateway 11-bit 710 F45B", ["ATSP6", "ATSH710", "ATCRA77A"], "22F45B"),
        ("Gateway 11-bit 710 028C", ["ATSP6", "ATSH710", "ATCRA77A"], "22028C"),
    ]

    // MARK: State (queue-confined)

    private let queue = DispatchQueue(label: "id3maps.obd")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var state = "av"
    private var rxBuffer = ""
    private var pending: [String] = []          // commands waiting to be sent
    private var waiting: String?                // command awaiting its ">" prompt
    private var responseHandler: ((String) -> Void)?
    private var ready = false
    private var timer: DispatchSourceTimer?
    private var lastRaw: String?
    private var lastSocPct: Double?
    private var bmsPct: Double?
    private var lastResidual: Double?
    private var lastValidated = false
    private var diagnosticsPending = false
    private var diagRunning = false
    /// The diagnostic request to send once the pending setup commands are through.
    private var diagNext: (label: String, request: String, index: Int)?
    private var firmware: String?
    private var volt12: String?
    private var lastAnswer: Date?
    private var okCount = 0
    private var failCount = 0
    private var extras: [String: String] = [:]
    private var tick = 0
    private var connectedAt = Date()
    /// After a deliberate idle disconnect: do not reconnect before this, so the dongle can sleep.
    private var idleBackoffUntil = Date.distantPast
    private var scanQueue: [String] = []
    private var scanTotal = 0
    private var scanHits = 0
    private var scanProgress: String?
    private var lastKeychainWrite = Date.distantPast

    private func statusLocked() -> Status {
        Status(state: state, device: peripheral?.name, lastRaw: lastRaw, lastSocPct: lastSocPct,
               validated: lastValidated,
               calibration: { let c = calibration(); return String(format: "vist = %.3f × BMS %+.2f (%d sammenligninger)", c.slope, c.intercept, c.pairs) }(),
               decoded: decodedLocked.map { OBDDecoded(label: $0.0, value: $0.1) },
               firmware: firmware, volt12: volt12, lastAnswer: lastAnswer, okCount: okCount, failCount: failCount,
               extras: Self.extraDIDs.compactMap { d in extras[d].map { OBDExtra(did: d, hex: $0) } }, scanProgress: scanProgress)
    }

    private func log(_ s: String) { SharedLog.shared.log(s, category: "obd") }

    // MARK: Lifecycle

    private func startLocked() {
        guard enabled else { state = "slået fra"; return }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreId])
        } else if central?.state == .poweredOn {
            connectOrScanLocked()
        }
    }

    private func stopLocked() {
        timer?.cancel(); timer = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil; writeChar = nil; notifyChar = nil; ready = false
        state = "slået fra"
    }

    private func connectOrScanLocked() {
        guard let central else { return }
        if let p = peripheral, p.state == .connected { p.delegate = self; p.discoverServices(nil); return } // restored connection
        if let idString = UserDefaults.standard.string(forKey: Self.deviceKey), let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            state = "venter på donglen (tænd bilen)"
            central.connect(known) // pending: completes whenever the dongle appears, also in background
            return
        }
        state = "søger efter donglen…"
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectOrScanLocked()
        case .unauthorized: state = "Bluetooth-tilladelse mangler"
        case .poweredOff: state = "Bluetooth er slået fra"
        default: state = "Bluetooth ikke klar"
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
            log("OBD: restored by iOS")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "").lowercased()
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard Self.nameHints.contains(where: { name.contains($0) }) || services.contains(where: { Self.serviceUUIDs.contains($0) })
        else { return }
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = "forbinder til \(p.name ?? "dongle")…"
        log("OBD: found \(p.name ?? "?")")
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.deviceKey)
        connectedAt = Date()
        lastAnswer = nil
        state = "forbundet, finder kanal…"
        log("OBD: connected \(p.name ?? "?")")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        state = "kunne ikke forbinde, prøver igen"
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        timer?.cancel(); timer = nil
        ready = false; writeChar = nil; notifyChar = nil; waiting = nil; pending = []
        state = "venter på donglen (tænd bilen)"
        log("OBD: disconnected")
        guard enabled else { return }
        let wait = idleBackoffUntil.timeIntervalSinceNow
        if wait > 0 {
            state = "bilen er slukket – donglen sover"
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.enabled, self.peripheral?.state != .connected else { return }
                self.central?.connect(p) // re-arm: completes when the car (and dongle) wake up
            }
        } else {
            central.connect(p) // re-arm the pending connection
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if notifyChar == nil, c.properties.contains(.notify) { notifyChar = c; p.setNotifyValue(true, for: c) }
            if writeChar == nil, c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) { writeChar = c }
        }
        guard writeChar != nil, notifyChar != nil, !ready else { return }
        ready = true
        state = "initialiserer…"
        rxBuffer = ""
        pending = Self.setup + ["ATI", "ATRV"]
        responseHandler = nil
        sendNextLocked()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value, let text = String(data: data, encoding: .ascii) else { return }
        rxBuffer += text
        guard rxBuffer.contains(">") else { return }
        let reply = rxBuffer.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        rxBuffer = ""
        let handler = responseHandler
        let cmd = waiting
        responseHandler = nil
        waiting = nil
        if cmd == "ATI" { firmware = reply }
        if cmd == "ATRV" { volt12 = reply }
        handler?(reply)
        sendNextLocked()
    }

    // MARK: ELM327 command flow

    /// Hard safety rule: only dongle settings ("AT…") and UDS ReadDataByIdentifier ("22" + 4 hex)
    /// ever leave this app. No coding, writing, security access, routines or session changes.
    static func isAllowed(_ cmd: String) -> Bool {
        let c = cmd.uppercased()
        if c.hasPrefix("AT") { return c.allSatisfy { $0.isLetter || $0.isNumber } }
        return c.count == 6 && c.hasPrefix("22") && c.allSatisfy(\.isHexDigit)
    }

    private func send(_ cmd: String, then handler: ((String) -> Void)? = nil) {
        guard Self.isAllowed(cmd) else { log("OBD: blocked non-read command \(cmd)"); return }
        guard let p = peripheral, let w = writeChar else { return }
        waiting = cmd
        responseHandler = handler
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: w, type: type)
        // Never hang on a lost prompt.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.waiting == cmd else { return }
            self.waiting = nil; self.responseHandler = nil; self.rxBuffer = ""
            self.sendNextLocked()
        }
    }

    private func sendNextLocked() {
        guard ready, waiting == nil else { return }
        if !pending.isEmpty {
            let cmd = pending.removeFirst()
            send(cmd)
            return
        }
        if !scanQueue.isEmpty {
            let did = scanQueue.removeFirst()
            send("22" + did) { reply in
                let compact = reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "")
                if let r = compact.range(of: "62" + did) {
                    self.scanHits += 1
                    self.log("OBD scan \(did): \(compact[r.upperBound...].prefix(40))")
                }
                let done = self.scanTotal - self.scanQueue.count
                self.scanProgress = "\(done)/\(self.scanTotal), \(self.scanHits) svar"
                if self.scanQueue.isEmpty {
                    self.diagRunning = false
                    self.scanProgress = "færdig: \(self.scanHits) svar af \(self.scanTotal) (se loggen)"
                    self.log("OBD scan done: \(self.scanHits) answers")
                    self.pending = Self.setup
                }
            }
            return
        }
        if let d = diagNext {
            diagNext = nil
            send(d.request) { reply in
                self.log("OBD test \(d.label): \(reply.replacingOccurrences(of: "\r", with: " | "))")
                self.queue.async { self.runCandidatesLocked(index: d.index + 1) }
            }
            return
        }
        if diagnosticsPending { diagnosticsPending = false; runCandidatesLocked(index: 0); return }
        if timer == nil && !diagRunning { startPollingLocked() }
    }

    private func kickLocked() { sendNextLocked() }

    private func startScanLocked() {
        guard ready else { scanProgress = "donglen er ikke forbundet"; return }
        var dids: [String] = []
        for base in [0x1E00, 0x0280, 0x2A00, 0x74C0] {
            let count = base == 0x1E00 ? 0x50 : 0x20
            for i in 0..<count { dids.append(String(format: "%04X", base + i)) }
        }
        timer?.cancel(); timer = nil
        diagRunning = true
        scanQueue = dids
        scanTotal = dids.count
        scanHits = 0
        scanProgress = "starter…"
        log("OBD scan: \(dids.count) identifiers")
        pending = ["ATSP7", "ATSH17FC007B", "ATCRA17FE007B", "ATST32"] // shorter timeout while scanning
        sendNextLocked()
    }

    private func startPollingLocked() {
        state = "læser batteriet"
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.ready, self.waiting == nil, self.pending.isEmpty,
                  !self.diagRunning, self.scanQueue.isEmpty else { return }
            self.tick += 1
            // Car off (no good answer for 3 min): drop the link so the dongle can sleep and
            // spare the 12 V battery. The pending reconnect wakes us when the car starts again.
            if let p = self.peripheral, Date().timeIntervalSince(self.lastAnswer ?? self.connectedAt) > 180 {
                self.log("OBD: car silent for 3 min, disconnecting so the dongle can sleep")
                self.idleBackoffUntil = Date().addingTimeInterval(15 * 60)
                self.central?.cancelPeripheralConnection(p)
                return
            }
            if self.tick % 12 == 0 {                    // every ~60 s: the car's 12 V battery
                self.send("ATRV")
            } else if self.tick % 3 == 0 {              // every ~15 s: one extra battery value, in turn
                let did = Self.extraDIDs[(self.tick / 3) % Self.extraDIDs.count]
                self.send("22" + did) { reply in
                    let c = reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "")
                    if let r = c.range(of: "62" + did) { self.extras[did] = String(c[r.upperBound...].prefix(16)) }
                }
            } else {
                self.send(Self.pollCommand) { reply in self.handlePoll(reply) }
            }
        }
        t.resume()
        timer = t
    }

    private func runCandidatesLocked(index: Int) {
        diagRunning = true
        guard index < Self.candidates.count else {
            diagRunning = false
            log("OBD test: done; restoring default setup")
            pending = Self.setup
            sendNextLocked()
            return
        }
        timer?.cancel(); timer = nil
        let (label, setupCmds, request) = Self.candidates[index]
        // Setup commands first; sendNextLocked sends the request (and logs it) once they are through.
        pending = setupCmds
        diagNext = (label, request, index)
        sendNextLocked()
    }

    // MARK: Parsing + calibration

    /// Battery-controller SoC (0x028C, byte / 2.5 = % of the WHOLE pack) -> the SoC the car shows.
    /// VW keeps a hidden buffer, so the display is roughly (BMS - 5) / 0.9 (MEB). That prior is
    /// refined from pairs with the Smartcar SoC (the car's displayed value): offset from any pair,
    /// slope too once the pairs span >= 15 percentage points.
    private static let calKey = "obdCalibration"
    private static let pairsKey = "obdPairs"

    private struct Calibration: Codable { var slope: Double; var intercept: Double; var pairs: Int }

    private func calibration() -> Calibration {
        if let d = UserDefaults.standard.data(forKey: Self.calKey), let c = try? JSONDecoder().decode(Calibration.self, from: d) { return c }
        return Calibration(slope: 1 / 0.9, intercept: -5 / 0.9, pairs: 0)
    }

    /// Learns from a fresh Smartcar value (< 2 min old, not yet used). Returns the latest residual.
    private func learnPair(bms: Double) -> Double? {
        guard let cloud: VehicleState = SharedStore.codable(.lastState),
              Date().timeIntervalSince(cloud.measuredAt) < 120 else { return nil }
        var pairs = (UserDefaults.standard.array(forKey: Self.pairsKey) as? [[Double]]) ?? []
        let t = cloud.measuredAt.timeIntervalSince1970
        if pairs.last?[2] != t {
            pairs.append([bms, cloud.stateOfCharge * 100, t])
            pairs = Array(pairs.suffix(40))
            UserDefaults.standard.set(pairs, forKey: Self.pairsKey)
            var cal = calibration()
            let ys = pairs.map { $0[1] }
            if pairs.count >= 6, (ys.max() ?? 0) - (ys.min() ?? 0) >= 15 {
                let xs = pairs.map { $0[0] }, n = Double(pairs.count)
                let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
                let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
                let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
                if sxx > 0 { cal.slope = min(1.3, max(0.9, sxy / sxx)); cal.intercept = my - cal.slope * mx }
            } else {
                // Keep the slope, fit the offset (median residual: whole-percent rounding is noisy).
                let offs = pairs.map { $0[1] - cal.slope * $0[0] }.sorted()
                cal.intercept = offs[offs.count / 2]
            }
            cal.pairs = pairs.count
            UserDefaults.standard.set(try? JSONEncoder().encode(cal), forKey: Self.calKey)
            log(String(format: "OBD: calibration pair BMS %.1f %% = car %.0f %% -> display = %.3f x BMS %+.2f (%d pairs)",
                       bms, cloud.stateOfCharge * 100, cal.slope, cal.intercept, cal.pairs))
        }
        let cal = calibration()
        return cloud.stateOfCharge * 100 - (cal.slope * bms + cal.intercept)
    }

    private func handlePoll(_ reply: String) {
        let compact = reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "")
        lastRaw = String(compact.prefix(40))
        guard let r = compact.range(of: Self.pollMarker) else {
            failCount += 1
            state = "intet svar fra batteriet (\(compact.prefix(16)))"
            return
        }
        let hex = compact[r.upperBound...].prefix(2)
        guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { failCount += 1; return }
        okCount += 1
        lastAnswer = Date()
        let bms = Double(byte) / 2.5
        bmsPct = bms
        if let residual = learnPair(bms: bms) { lastResidual = residual }
        let cal = calibration()
        let pct = min(100, max(0, cal.slope * bms + cal.intercept))
        lastSocPct = pct
        // Only for Maps once at least one real comparison exists and it agrees within 2 pp.
        lastValidated = cal.pairs > 0 && abs(lastResidual ?? 99) <= 2
        state = String(format: "live: %.1f %%", pct) + (lastValidated ? "" : " (afventer sammenligning med Smartcar)")
        let reading = OBDReading(soc: pct / 100, at: Date(), validated: lastValidated)
        // Keychain write at most every 10 s, or immediately on a whole-percent change.
        let changed = (SharedStore.codable(.obdReading) as OBDReading?).map { Int($0.soc * 100) != Int(pct) || $0.validated != lastValidated } ?? true
        if changed || Date().timeIntervalSince(lastKeychainWrite) >= 10 {
            SharedStore.setCodable(reading, for: .obdReading)
            lastKeychainWrite = Date()
        }
    }

    // MARK: Decoded battery values (from the scan of 21 Nov 2026; interpretation see comments)

    /// 1E40-1E4F: 16 battery temperature sensors, °C = raw / 64 - 40 (0A04 -> 0.06 °C on a cold morning).
    static let tempDIDs = (0x1E40...0x1E4F).map { String(format: "%04X", $0) }

    private func u(_ hex: String, bytes: Int) -> Double? {
        guard hex.count >= bytes * 2, let v = UInt32(hex.prefix(bytes * 2), radix: 16) else { return nil }
        return Double(v)
    }

    var decodedLocked: [(String, String)] {
        var out: [(String, String)] = []
        let temps = Self.tempDIDs.compactMap { extras[$0] }.compactMap { u($0, bytes: 2) }.map { $0 / 64 - 40 }
        if !temps.isEmpty {
            let avg = temps.reduce(0, +) / Double(temps.count)
            out.append(("Batteritemperatur", String(format: "%.1f °C (min %.1f / max %.1f, %d følere)", avg, temps.min()!, temps.max()!, temps.count)))
        }
        if let v = extras["1E3B"].flatMap({ u($0, bytes: 2) }) {
            let volts = v / 4
            out.append(("Højspænding", String(format: "%.0f V", volts)))
            if let a = extras["1E3D"].flatMap({ u($0, bytes: 3) }) {
                let amps = a / 100 // foreløbig tolkning: 000244 -> 5.8 A while the heating ran
                out.append(("Strøm (foreløbig)", String(format: "%.1f A ≈ %.1f kW", amps, amps * volts / 1000)))
            }
        }
        if let b = bmsPct { out.append(("Batteristyring (hele batteriet)", String(format: "%.1f %%", b))) }
        return out
    }
}
