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
import WidgetKit

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
        /// Battery output (kW) from the energy counter during this drive, oldest first.
        var power: [PowerPoint] = []
        /// The survey of the car's other control units: progress and the values found.
        var survey: String?
        var surveyValues: [OBDDecoded] = []
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

    /// CarPlay connected ("Start kørsel"): the car is on and unlocked, so the dongle may talk.
    func beginDrive() {
        queue.async {
            UserDefaults.standard.set(Date(), forKey: Self.driveKey)
            self.silentStop = false
            self.log("OBD: drive started, dongle allowed")
            CarPlayRoute.shared.logState(reason: "Start kørsel", force: true)
            guard self.enabled else { return }
            if let p = self.peripheral, p.state != .connected { self.central?.connect(p) } else { self.startLocked() }
        }
    }

    /// CarPlay disconnected ("Slut kørsel"): stop talking at once and drop the link, before the
    /// car can be locked. Talking to a locked car set off its alarm (21 Nov).
    func endDrive() {
        CarPlayRoute.shared.logState(reason: "Slut kørsel", force: true)
        queue.sync {
            UserDefaults.standard.removeObject(forKey: Self.driveKey)
            self.disconnectLocked(reason: "drive ended")
        }
    }

    /// The dongle may only talk while a drive is active (CarPlay connected). In case an end event
    /// was missed, the drive also expires 2 hours after the car last moved; any length of drive
    /// keeps it alive (the timestamp is renewed while moving).
    private var driveActive: Bool {
        guard let d = UserDefaults.standard.object(forKey: Self.driveKey) as? Date else { return false }
        return Date().timeIntervalSince(d) < 2 * 3600
    }

    private func renewDriveLocked() {
        guard let d = UserDefaults.standard.object(forKey: Self.driveKey) as? Date,
              Date().timeIntervalSince(d) > 60, driveActive else { return }
        UserDefaults.standard.set(Date(), forKey: Self.driveKey)
    }

    /// Ends the drive for good (persisted), so neither a timer, a reconnect nor an iOS relaunch
    /// can talk to the car again before the next "Start kørsel".
    private func stopDriveLocked(reason: String) {
        UserDefaults.standard.removeObject(forKey: Self.driveKey)
        silentStop = true
        log("OBD: stopped until next drive (\(reason))")
        huntReportLocked(force: true)
        disconnectLocked(reason: reason)
    }

    /// Car on = the DC/DC converter charges the 12 V battery (about 14 V). Parked = about 12.x V.
    /// ATRV is answered by the dongle itself and puts nothing on the car's bus.
    static let carOnVolts = 13.0

    private func handleVolts(_ reply: String) {
        let digits = reply.filter { $0.isNumber || $0 == "." }
        guard let v = Double(digits), v > 5, v < 20 else { return }
        voltMax = max(voltMax ?? v, v)
        if !carOn {
            if v >= Self.carOnVolts {
                carOn = true
                log(String(format: "OBD: 12 V %.1f V – car is on, reading allowed", v))
            } else {
                log(String(format: "OBD: 12 V %.1f V – car not on, waiting", v))
            }
            return
        }
        // The converter stopped: the car was switched off. Stop before it can be locked.
        if let m = voltMax, v < Self.carOnVolts, v <= m - 0.8 {
            stopDriveLocked(reason: String(format: "12 V fell from %.1f to %.1f V – car off", m, v))
        }
    }

    private func carAnswered(_ ok: Bool) {
        if ok { carFails = 0; return }
        carFails += 1
        if carFails >= 2 { stopDriveLocked(reason: "no answer from the car twice in a row") }
    }

    private func disconnectLocked(reason: String) {
        timer?.cancel(); timer = nil
        hunt.save()
        survey.save()
        headerForeign = false
        endEnergyDriveLocked()
        central?.stopScan()
        if let p = peripheral, p.state != .disconnected {
            central?.cancelPeripheralConnection(p)
            log("OBD: disconnected (\(reason))")
        }
        ready = false; writeChar = nil; notifyChar = nil; waiting = nil; pending = []
        state = enabled ? "venter på kørsel (bruges kun med CarPlay forbundet)" : "slået fra"
    }

    /// Runs the list of candidate requests once and logs every raw answer.
    func runDiagnostics() { queue.async { self.diagnosticsPending = true; self.kickLocked() } }

    // MARK: Configuration

    private static let enabledKey = "obdEnabled"
    private static let driveKey = "obdDriveActiveSince"
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
    /// Last valid GPS speed (km/h), for the power log line.
    private var lastSpeedKmh: Double?
    /// Index into the non-power extra DIDs (temperatures etc.), read in turn.
    private var restIndex = 0
    private var drainUntil: Date?
    /// Search for the traction-current identifier (read-only, during drives, survives restarts).
    private var hunt = CurrentHunt.load()
    /// Survey of the other control units (read-only, during drives, survives restarts).
    private var survey = BusSurvey.load()
    /// The dongle is addressed to another unit than the BMS: restore before the next request.
    private var headerForeign = false
    private static let bmsHeader = ["ATSH17FC007B", "ATCRA17FE007B"]
    private var lastHuntReport = Date()
    /// Recent valid GPS speeds (m/s) for the acceleration of hunt samples.
    private var speedHist: [(t: Date, v: Double)] = []
    /// Road-load energy (Wh) integrated from GPS speed since the app started (for the hunt).
    private var roadEnergyWh = 0.0
    private var connectedAt = Date()
    /// Set when the car went silent during a drive: no reconnect until the next drive start.
    private var silentStop = false
    /// Car requests ("22…") in a row that got no valid answer. Two in a row ends the drive.
    private var carFails = 0
    /// Highest 12 V reading (dongle-local ATRV) since connecting, and whether it showed the car on.
    private var voltMax: Double?
    private var carOn = false
    /// GPS: last fix and last fix at driving speed. Car requests only go out while the car moves,
    /// so nothing is on the bus when you stop, get out and lock (the car can't be locked while moving).
    private var lastFixAt: Date?
    private var lastMovingAt: Date?
    private var paused = true
    private var resumedAt = Date()

    /// Called by GPSRecorder for every fix (any thread).
    func noteGPS(speed: Double, valid: Bool, at t: Date) {
        queue.async {
            self.lastFixAt = t
            if valid && speed >= 0 {
                self.lastSpeedKmh = speed * 3.6
                if let last = self.speedHist.last {
                    let dt = t.timeIntervalSince(last.t)
                    if dt > 0, dt < 5 {
                        let p = CurrentHunt.roadPowerW(v: (speed + last.v) / 2, a: (speed - last.v) / dt)
                        self.roadEnergyWh += min(150_000, max(-60_000, p)) * dt / 3600
                    }
                }
                self.speedHist.append((t, speed))
                self.speedHist.removeAll { t.timeIntervalSince($0.t) > 8 }
            }
            if valid && speed >= 1.5 { self.lastMovingAt = t; self.renewDriveLocked() }   // ~5 km/h
        }
    }

    /// Speed (m/s) and acceleration (m/s²) right now, from the last few GPS fixes.
    private func motionLocked() -> (v: Double, a: Double)? {
        guard let last = speedHist.last, Date().timeIntervalSince(last.t) < 3 else { return nil }
        guard let first = speedHist.first(where: { last.t.timeIntervalSince($0.t) <= 4 }) else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        guard dt >= 1.5 else { return nil }
        return (last.v, (last.v - first.v) / dt)
    }

    private func huntReportLocked(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastHuntReport) >= 5 * 60 else { return }
        lastHuntReport = Date()
        hunt.save()
        hunt.report().forEach { log($0) }
        survey.save()
        survey.report().forEach { log($0) }
    }

    private var movingNow: Bool {
        guard let f = lastFixAt, let m = lastMovingAt else { return false }
        return Date().timeIntervalSince(f) < 10 && Date().timeIntervalSince(m) < 3
    }
    private var scanQueue: [String] = []
    private var scanTotal = 0
    private var scanHits = 0
    private var scanProgress: String?
    private var lastKeychainWrite = Date.distantPast
    private var lastWidgetPct: Int?
    private var lastWidgetReload = Date.distantPast

    private func statusLocked() -> Status {
        Status(state: state, device: peripheral?.name, lastRaw: lastRaw, lastSocPct: lastSocPct,
               validated: lastValidated,
               calibration: { let c = calibration(); return String(format: "vist = %.3f × BMS %+.2f (%d sammenligninger)", c.slope, c.intercept, c.pairs) }(),
               decoded: decodedLocked.map { OBDDecoded(label: $0.0, value: $0.1) },
               firmware: firmware, volt12: volt12, lastAnswer: lastAnswer, okCount: okCount, failCount: failCount,
               extras: Self.extraDIDs.compactMap { d in extras[d].map { OBDExtra(did: d, hex: $0) } }, scanProgress: scanProgress,
               power: powerSeries, survey: survey.progress,
               surveyValues: survey.shown.map { OBDDecoded(label: $0.0, value: $0.1) })
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
        guard driveActive else {
            // Parked: never connect (also not when iOS restores us in the background).
            if let p = peripheral, p.state != .disconnected { central.cancelPeripheralConnection(p) }
            state = "venter på kørsel (bruges kun med CarPlay forbundet)"
            return
        }
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
            log("OBD: restored by iOS" + (driveActive ? "" : " – no drive active, disconnecting"))
            if !driveActive { central.cancelPeripheralConnection(restored) }
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
        guard driveActive else {
            log("OBD: connected while no drive is active – disconnecting")
            central.cancelPeripheralConnection(p)
            return
        }
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.deviceKey)
        connectedAt = Date()
        lastAnswer = nil
        carFails = 0
        voltMax = nil
        carOn = false
        paused = true
        lastResidual = nil      // trust is earned again on every connection
        powerWin = PowerWindow(); lastPowerAt = nil; energyKwh = 0; energySignedKwh = 0; voltsAt = nil; drainUntil = nil
        state = "forbundet, finder kanal…"
        log("OBD: connected \(p.name ?? "?")")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard driveActive else { return }
        state = "kunne ikke forbinde, prøver igen"
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        timer?.cancel(); timer = nil
        ready = false; writeChar = nil; notifyChar = nil; waiting = nil; pending = []
        state = "venter på donglen (tænd bilen)"
        log("OBD: disconnected")
        // Reconnect only during an active drive that has not gone silent; otherwise wait for
        // the next "Start kørsel".
        guard enabled, driveActive, !silentStop else {
            state = "venter på kørsel (bruges kun med CarPlay forbundet)"
            return
        }
        central.connect(p)
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
        if cmd == "ATRV" { volt12 = reply; handleVolts(reply) }
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
        // Last line of defence: nothing goes to the car outside an active drive.
        guard driveActive, !silentStop else { disconnectLocked(reason: "no drive active"); return }
        let toCar = !cmd.uppercased().hasPrefix("AT")
        // Nothing reaches the car's bus until the dongle's own 12 V reading shows the car is on.
        // …and only while the car is moving (also blocks manual tests/scans while parked).
        guard !toCar || (carOn && movingNow) else {
            // A manual test/scan must not stall: report the skipped request and move on.
            if diagRunning { handler?("SKIPPED (holder stille)") }
            queue.async { self.sendNextLocked() }
            return
        }
        guard let p = peripheral, let w = writeChar else { return }
        waiting = cmd
        responseHandler = handler
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: w, type: type)
        // Never hang on a lost prompt.
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.waiting == cmd else { return }
            self.waiting = nil; self.responseHandler = nil; self.rxBuffer = ""
            // Only the SoC poll judges whether the car answers. Extra values (voltage, current,
            // temperatures) are slow or unsupported now and then; on 26 Nov two such timeouts
            // stopped the dongle after a minute of driving. A late reply is drained, not counted.
            if cmd == Self.pollCommand { self.carAnswered(false) }
            self.drainUntil = Date().addingTimeInterval(2)
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
        t.schedule(deadline: .now(), repeating: 1)   // 1 s ticks; each request below has its own period
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Hard gate before every request: no drive, no talking.
            guard self.driveActive else { self.disconnectLocked(reason: "no drive active"); return }
            guard self.ready, self.waiting == nil, self.pending.isEmpty,
                  !self.diagRunning, self.scanQueue.isEmpty else { return }
            // Give a late answer to a timed-out request time to arrive and be thrown away, so it
            // is never read as the answer to the next request.
            if let d = self.drainUntil, Date() < d { return }
            self.drainUntil = nil
            // A survey read went to another unit: address the BMS again before anything else
            // (also after a timeout, when the survey's own reply handler never ran).
            if self.headerForeign {
                self.headerForeign = false
                self.pending = Self.bmsHeader
                self.sendNextLocked()
                return
            }
            self.tick += 1
            // Stage 1: only log whether iOS reports CarPlay while we would talk to the car.
            CarPlayRoute.shared.logState(reason: "OBD poll")
            // Car never showed as on (12 V stayed low) within 60 s: give up until the next drive.
            if !self.carOn {
                if Date().timeIntervalSince(self.connectedAt) > 60 {
                    self.stopDriveLocked(reason: "12 V never showed the car on")
                } else if self.tick % 5 == 0 {
                    self.send("ATRV")
                }
                return
            }
            // Standing still (or no GPS): no car requests, only the dongle's own 12 V check.
            if !self.movingNow {
                if !self.paused { self.paused = true; self.state = "holder stille – læser ikke bilen"; self.log("OBD: standing still, car requests paused") }
                if self.tick % 15 == 0 { self.send("ATRV") }
                // Standing still the SoC does not move, so the last live value stays true. Re-stamp
                // it (up to 10 min after the last real answer) so Maps doesn't fall back to the
                // 2-5 min old cloud value at every red light. Paused anyway on a switch-off (12 V).
                if self.tick % 15 == 1, self.lastValidated, let pct = self.lastSocPct,
                   let a = self.lastAnswer, Date().timeIntervalSince(a) < 10 * 60 {
                    SharedStore.setCodable(OBDReading(soc: pct / 100, at: Date(), validated: true), for: .obdReading)
                }
                return
            }
            if self.paused { self.paused = false; self.resumedAt = Date(); self.log("OBD: moving, car requests resumed") }
            // Car off (no good answer for 20 s of driving): stop and stay quiet until the next drive.
            if Date().timeIntervalSince(max(self.lastAnswer ?? self.connectedAt, self.resumedAt)) > 20 {
                self.stopDriveLocked(reason: "car silent for 20 s")
                return
            }
            // Periods (2 s ticks, 30 s cycle): 12 V every 30 s, SoC every 6 s, voltage every 30 s,
            // one of the remaining values every 30 s, and the current hunt in the other 7 slots.
            // 1 s ticks overloaded the dongle (26 Nov: only 11 answers in 30 s, then two timeouts
            // and a stop). 1E3D turned out NOT to be the traction current (steady ~5.5 A at any
            // speed); the hunt below looks for the real one.
            guard self.tick % 2 == 0 else { return }
            self.huntReportLocked()
            let slot = (self.tick / 2) % 15
            if slot == 0 {                               // 12 V (dongle only) – detects switch-off
                self.send("ATRV")
            } else if slot % 3 == 1 {
                self.send(Self.pollCommand) { reply in self.handlePoll(reply) }
            } else {
                let did: String
                let isHunt: Bool
                if slot == 5 || slot == 11 {
                    did = "1E2D"; isHunt = false         // energy counter, every 15 s
                } else if slot == 14 {
                    did = "1E2C"; isHunt = false         // second counter, every 30 s
                } else if slot == 8 {
                    let rest = Self.extraDIDs.filter { $0 != "1E3B" && $0 != "1E3D" }
                    did = rest[self.restIndex % rest.count]
                    self.restIndex += 1
                    isHunt = false
                } else if slot == 2 {
                    did = "1E3B"; isHunt = false
                } else if (slot == 6 || slot == 12), self.surveyLocked() {
                    return                               // other control units, every 15 s
                } else if let h = self.hunt.nextDID() {
                    did = h; isHunt = true
                } else {
                    did = "1E3D"; isHunt = false
                }
                self.send("22" + did) { reply in
                    let c = reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "")
                    if let r = c.range(of: "62" + did) {
                        self.extras[did] = String(c[r.upperBound...].prefix(16))
                        if did == "1E3B" { self.voltsAt = Date() }
                        if did == "1E3D" { self.addPowerSampleLocked() }
                        if Self.energyDIDs.contains(did), let raw = Int(c[r.upperBound...].prefix(4), radix: 16) {
                            self.recordEnergyLocked(did: did, raw: raw)
                        }
                    }
                    if isHunt {
                        let m = self.motionLocked()
                        self.hunt.record(did: did, payload: CurrentHunt.payload(reply: c, did: did),
                                         speedMs: m?.v, accel: m?.a, roadEnergyWh: self.roadEnergyWh)
                        if self.hunt.discoveryDone && !self.hunt.discoveryLogged {
                            self.hunt.discoveryLogged = true
                            self.log(self.hunt.respondersLine())
                            self.hunt.save()
                        }
                    }
                    // Only a success counts here (some extra values may be unsupported);
                    // missing answers are judged on the main SoC poll.
                    if c.contains("62" + did) || c.contains("7F22") { self.carAnswered(true) }
                }
            }
        }
        t.resume()
        timer = t
    }

    /// One survey request (see BusSurvey). Returns false when the survey has nothing to ask.
    /// Another unit is addressed with dongle settings only (ATSH/ATCRA); the tick restores the
    /// BMS address right after (headerForeign).
    private func surveyLocked() -> Bool {
        guard let req = survey.next() else { return false }
        let ecu = req.ecu, did = req.did, kind = req.kind
        let read = {
            self.send("22" + did) { reply in
                switch kind {
                case .unit:
                    let before = self.survey.ecus.count
                    self.survey.recordUnit(ecu: ecu, reply: reply)
                    if self.survey.ecus.count > before {
                        self.log("OBD survey: unit at 17FC00\(ecu) answers (part no. \(self.survey.ecus[ecu] ?? "?"))")
                    }
                    if self.survey.unitsDone { self.huntReportLocked(force: true) }
                case .value, .track:
                    let m = self.motionLocked()
                    let isNew = self.survey.responders[ecu + ":" + did] == nil
                    let hex = self.survey.recordValue(ecu: ecu, did: did, reply: reply, v: m?.v, a: m?.a, e: self.roadEnergyWh)
                    if isNew, self.survey.responders[ecu + ":" + did] != nil {
                        self.log("OBD survey value \(ecu):\(did) = \(hex ?? self.survey.names[ecu] ?? "")")
                    }
                }
                // The BMS answering counts as the car answering; other units may stay silent.
                if ecu == BusSurvey.homeEcu, BusSurvey.compact(reply).contains("17FE007B") { self.carAnswered(true) }
            }
        }
        if ecu == BusSurvey.homeEcu {
            read()
        } else {
            headerForeign = true
            send("ATSH17FC00" + ecu) { _ in self.send("ATCRA17FE00" + ecu) { _ in read() } }
        }
        return true
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
    // v2: pairs are now matched by time (v1 paired a minutes-old cloud value with the BMS value
    // of "now", which was several pp off while fast charging), so the old pairs are dropped.
    private static let calKey = "obdCalibration2"
    private static let pairsKey = "obdPairs2"
    /// Recent BMS readings, so a cloud value can be paired with what the BMS said at that moment.
    private var bmsHistory: [(t: TimeInterval, bms: Double)] = []

    private struct Calibration: Codable { var slope: Double; var intercept: Double; var pairs: Int }

    private func calibration() -> Calibration {
        if let d = UserDefaults.standard.data(forKey: Self.calKey), let c = try? JSONDecoder().decode(Calibration.self, from: d) { return c }
        return Calibration(slope: 1 / 0.9, intercept: -5 / 0.9, pairs: 0)
    }

    /// Learns from a recent Smartcar value (< 10 min old, not yet used). Returns the latest residual.
    /// (VW's values reach us 1-5 min after the car measured them, so 2 min was too strict.)
    private func learnPair(bms now: Double) -> Double? {
        let tNow = Date().timeIntervalSince1970
        bmsHistory.append((tNow, now))
        bmsHistory.removeAll { tNow - $0.t > 900 }
        guard let cloud: VehicleState = SharedStore.codable(.lastState),
              Date().timeIntervalSince(cloud.measuredAt) < 600 else { return nil }
        // The BMS value closest to when the car measured the cloud value (within 30 s).
        let tc = cloud.measuredAt.timeIntervalSince1970
        guard let match = bmsHistory.min(by: { abs($0.t - tc) < abs($1.t - tc) }), abs(match.t - tc) <= 30 else { return nil }
        let bms = match.bms
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
            // An answer to another value (a late reply that slipped through) is not silence.
            if compact.contains("621E") || compact.contains("622A") { return }
            carAnswered(false)
            failCount += 1
            state = "intet svar fra batteriet (\(compact.prefix(16)))"
            return
        }
        let hex = compact[r.upperBound...].prefix(2)
        guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { failCount += 1; return }
        okCount += 1
        carAnswered(true)
        lastAnswer = Date()
        let bms = Double(byte) / 2.5
        bmsPct = bms
        if let residual = learnPair(bms: bms) {
            lastResidual = residual
            // Far off: the stored calibration is wrong (e.g. learnt from bad pairs). Start over.
            if abs(residual) > 10 {
                UserDefaults.standard.removeObject(forKey: Self.pairsKey)
                UserDefaults.standard.removeObject(forKey: Self.calKey)
                log(String(format: "OBD: calibration off by %.0f pp – reset, learning again", residual))
            }
        }
        let cal = calibration()
        let pct = min(100, max(0, cal.slope * bms + cal.intercept))
        lastSocPct = pct
        // For Maps: trusted from the first second once >= 3 comparisons agreed; a fresh comparison
        // that is off by more than 3 pp suspends it until the calibration has caught up.
        // Trust: a comparison with VW on this connection decides. Before the first one, a well
        // established calibration (>= 10 pairs) is trusted, because VW can go quiet for 30+ min
        // while driving (24 Nov 16:40: Maps sat on a 33-min-old 36 % while the dongle was live).
        // Maps and the widget still reject a dongle value > 5 pp away from a recent VW value.
        if let r = lastResidual {
            lastValidated = cal.pairs >= 3 ? abs(r) <= 3 : abs(r) <= 2
        } else {
            lastValidated = cal.pairs >= 10
        }
        state = String(format: "live: %.1f %%", pct) + (lastValidated ? "" : " (afventer sammenligning med Smartcar)")
        let reading = OBDReading(soc: pct / 100, at: Date(), validated: lastValidated)
        // Keychain write at most every 10 s, or immediately on a whole-percent change.
        let changed = (SharedStore.codable(.obdReading) as OBDReading?).map { Int($0.soc * 100) != Int(pct) || $0.validated != lastValidated } ?? true
        if changed || Date().timeIntervalSince(lastKeychainWrite) >= 10 {
            SharedStore.setCodable(reading, for: .obdReading)
            lastKeychainWrite = Date()
        }
        // The widget (also in CarPlay) shows the live value: reload it on each new whole percent,
        // at most once a minute (iOS limits widget reloads per day).
        let whole = Int(pct.rounded())
        if lastValidated, whole != lastWidgetPct, Date().timeIntervalSince(lastWidgetReload) >= 60 {
            lastWidgetPct = whole
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Decoded battery values (from the scan of 21 Nov 2026; interpretation see comments)

    /// 1E40-1E4F: 16 battery temperature sensors, °C = raw / 64 - 40 (0A04 -> 0.06 °C on a cold morning).
    static let tempDIDs = (0x1E40...0x1E4F).map { String(format: "%04X", $0) }

    private func u(_ hex: String, bytes: Int) -> Double? {
        guard hex.count >= bytes * 2, let v = UInt32(hex.prefix(bytes * 2), radix: 16) else { return nil }
        return Double(v)
    }

    /// ~1 Hz current samples, summarised in the log every 30 s: average / min / max power with
    /// both readings of the sign (still unverified), average GPS speed, and energy integrated
    /// since the dongle connected. Raw values of the last sample are included for checking.
    private struct PowerWindow {
        var n = 0, sumKw = 0.0, sumSignedKw = 0.0, minKw = Double.infinity, maxKw = -Double.infinity
        var sumKmh = 0.0, nKmh = 0
        var start = Date()
    }
    private var powerWin = PowerWindow()
    private var lastPowerAt: Date?
    private var energyKwh = 0.0, energySignedKwh = 0.0
    private var voltsAt: Date?

    private func addPowerSampleLocked() {
        guard let rawA = extras["1E3D"], let a = u(rawA, bytes: 3),
              let rawV = extras["1E3B"], let v = u(rawV, bytes: 2).map({ $0 / 4 }),
              let va = voltsAt, Date().timeIntervalSince(va) < 45 else { return }
        let now = Date()
        let kw = a / 100 * v / 1000
        let signedKw = (a >= 0x800000 ? a - 0x1000000 : a) / 100 * v / 1000
        if let p = lastPowerAt {
            let dt = now.timeIntervalSince(p)
            if dt < 10 { energyKwh += kw * dt / 3600; energySignedKwh += signedKw * dt / 3600 }
        }
        lastPowerAt = now
        powerWin.n += 1; powerWin.sumKw += kw; powerWin.sumSignedKw += signedKw
        powerWin.minKw = min(powerWin.minKw, signedKw); powerWin.maxKw = max(powerWin.maxKw, signedKw)
        if let k = lastSpeedKmh, let f = lastFixAt, now.timeIntervalSince(f) < 10 { powerWin.sumKmh += k; powerWin.nKmh += 1 }
        guard now.timeIntervalSince(powerWin.start) >= 30 else { return }
        let w = powerWin
        var line = String(format: "OBD power %ds: %d samples, avg %.1f kW (signed %.1f, min %.1f / max %.1f)",
                          Int(now.timeIntervalSince(w.start)), w.n, w.sumKw / Double(w.n), w.sumSignedKw / Double(w.n), w.minKw, w.maxKw)
        line += w.nKmh > 0 ? String(format: " · %.0f km/t", w.sumKmh / Double(w.nKmh)) : " · fart ukendt"
        line += String(format: " · %.0f V · energy %.2f kWh (signed %.2f)", v, energyKwh, energySignedKwh)
        if let t = bmsPct { line += String(format: " · BMS %.1f %%", t) }
        line += " · raw A \(rawA.prefix(6)) V \(rawV.prefix(4))"
        log(line)
        powerWin = PowerWindow()
    }

    // MARK: Energy counters (1E2D / 1E2C)

    static let energyDIDs = ["1E2D", "1E2C"]
    private var counters: [String: EnergyCounter] = EnergyCounter.load()
    private var powerSeries: [PowerPoint] = []
    private var energyWin: [String: (counts: Double, dt: Double, n: Int)] = [:]
    private var energyWinStart = Date()
    private var lastPowerKw: Double?

    private var capacityWh: Double {
        let kwh = (SharedStore.codable(.lastState) as VehicleState?)?.model?.capacityKwhNet ?? 77
        return (40...100).contains(kwh) ? kwh * 1000 : 77_000
    }

    private func recordEnergyLocked(did: String, raw: Int) {
        var c = counters[did] ?? EnergyCounter(did: did)
        let now = Date()
        if let step = c.record(raw: raw, at: now, socPct: lastSocPct) {
            var w = energyWin[did] ?? (0, 0, 0)
            w.counts += step.counts; w.dt += step.dt; w.n += 1
            energyWin[did] = w
            if did == "1E2D", let s = c.whPerCount(socNow: lastSocPct, capacityWh: capacityWh) {
                let kw = step.counts * s / step.dt * 3.6
                lastPowerKw = kw
                powerSeries.append(PowerPoint(at: now, kw: kw))
                powerSeries.removeAll { now.timeIntervalSince($0.at) > 45 * 60 }
            }
        }
        counters[did] = c
        guard now.timeIntervalSince(energyWinStart) >= 60 else { return }
        for d in Self.energyDIDs {
            guard let w = energyWin[d], w.dt > 0, let k = counters[d] else { continue }
            var line = String(format: "OBD energy %@: %.1f counts/min (%d reads)", d, w.counts / w.dt * 60, w.n)
            if let s = k.whPerCount(socNow: lastSocPct, capacityWh: capacityWh) {
                line += String(format: " = %.1f kW · drive %.2f kWh · %.2f Wh/count (%d drives)",
                               w.counts * s / w.dt * 3.6, k.driveCounts * s / 1000, s, k.drives)
            } else {
                line += String(format: " · drive %.0f counts · scale not learnt yet (needs a 2 %% SoC drop)", k.driveCounts)
            }
            if let v = lastSpeedKmh, let f = lastFixAt, now.timeIntervalSince(f) < 10 { line += String(format: " · %.0f km/t", v) }
            if let p = lastSocPct { line += String(format: " · SoC %.1f %%", p) }
            log(line)
        }
        energyWin = [:]
        energyWinStart = now
        EnergyCounter.save(counters)
    }

    private func endEnergyDriveLocked() {
        for d in Self.energyDIDs {
            guard var c = counters[d] else { continue }
            if let line = c.endDrive(socPct: lastSocPct, capacityWh: capacityWh) { log(line) }
            counters[d] = c
        }
        EnergyCounter.save(counters)
    }

    var decodedLocked: [(String, String)] {
        var out: [(String, String)] = []
        if let c = counters["1E2D"] {
            if let s = c.whPerCount(socNow: lastSocPct, capacityWh: capacityWh) {
                if let kw = lastPowerKw { out.append(("Batteriets effekt (tæller)", String(format: "%.1f kW", kw))) }
                out.append(("Brugt denne tur (tæller)", String(format: "%.2f kWh · %.2f Wh pr. tæl", c.driveCounts * s / 1000, s)))
            } else if c.startSocPct != nil {
                out.append(("Energitæller", String(format: "%.0f tæl denne tur – skalaen læres, når batteriet er faldet 2 %%", c.driveCounts)))
            }
        }
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
