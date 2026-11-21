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

final class OBDManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = OBDManager()

    // MARK: Public status (read from the UI)

    struct Status: Sendable {
        var state: String
        var device: String?
        var lastRaw: String?
        var lastSocPct: Double?
        var validated: Bool
        var scale: Double?
    }

    func status() -> Status { queue.sync { statusLocked() } }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            queue.async { newValue ? self.startLocked() : self.stopLocked() }
        }
    }

    func start() { queue.async { self.startLocked() } }

    /// Runs the list of candidate requests once and logs every raw answer.
    func runDiagnostics() { queue.async { self.diagnosticsPending = true; self.kickLocked() } }

    // MARK: Configuration

    private static let enabledKey = "obdEnabled"
    private static let deviceKey = "obdDeviceUUID"
    private static let scaleKey = "obdScale"
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
    private static let pollMarker = "62028C"
    /// Candidate scalings of the single data byte (percent = byte / divisor).
    private static let divisors: [Double] = [2.5, 2.55, 1.0, 2.0]

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
    private var lastValidated = false
    private var diagnosticsPending = false
    private var diagRunning = false
    /// The diagnostic request to send once the pending setup commands are through.
    private var diagNext: (label: String, request: String, index: Int)?
    private var lastKeychainWrite = Date.distantPast

    private func statusLocked() -> Status {
        Status(state: state, device: peripheral?.name, lastRaw: lastRaw, lastSocPct: lastSocPct,
               validated: lastValidated, scale: UserDefaults.standard.object(forKey: Self.scaleKey) as? Double)
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
        if enabled { central.connect(p) } // re-arm the pending connection
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
        pending = Self.setup
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
        responseHandler = nil
        waiting = nil
        handler?(reply)
        sendNextLocked()
    }

    // MARK: ELM327 command flow

    private func send(_ cmd: String, then handler: ((String) -> Void)? = nil) {
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

    private func startPollingLocked() {
        state = "læser batteriet"
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.ready, self.waiting == nil, self.pending.isEmpty else { return }
            self.send(Self.pollCommand) { reply in self.handlePoll(reply) }
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

    // MARK: Parsing + validation

    private func handlePoll(_ reply: String) {
        let compact = reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "")
        lastRaw = String(compact.prefix(40))
        guard let r = compact.range(of: Self.pollMarker) else {
            state = "intet svar fra batteriet (\(compact.prefix(16)))"
            return
        }
        let hex = compact[r.upperBound...].prefix(2)
        guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { return }
        let scale = chooseScale(byte: Double(byte))
        guard let scale else {
            state = String(format: "læser rå værdi %d (afventer sammenligning med Smartcar)", byte)
            lastSocPct = nil; lastValidated = false
            return
        }
        let pct = min(100, max(0, Double(byte) / scale))
        lastSocPct = pct
        lastValidated = true
        state = String(format: "live: %.1f %%", pct)
        let reading = OBDReading(soc: pct / 100, at: Date(), validated: true)
        // Keychain write at most every 10 s, or immediately on a whole-percent change.
        let changed = (SharedStore.codable(.obdReading) as OBDReading?).map { Int($0.soc * 100) != Int(pct) } ?? true
        if changed || Date().timeIntervalSince(lastKeychainWrite) >= 10 {
            SharedStore.setCodable(reading, for: .obdReading)
            lastKeychainWrite = Date()
        }
    }

    /// The divisor that turns the raw byte into the SoC Smartcar reported (within 4 pp), checked
    /// only against a Smartcar value less than 20 minutes old. Once found it is remembered.
    private func chooseScale(byte: Double) -> Double? {
        if let known = UserDefaults.standard.object(forKey: Self.scaleKey) as? Double { return known }
        guard let cloud: VehicleState = SharedStore.codable(.lastState),
              Date().timeIntervalSince(cloud.measuredAt) < 20 * 60 else { return nil }
        let target = cloud.stateOfCharge * 100
        let best = Self.divisors.min { abs(byte / $0 - target) < abs(byte / $1 - target) }
        guard let best, abs(byte / best - target) <= 4 else {
            log(String(format: "OBD: raw %.0f matches no scale for Smartcar %.0f %%", byte, target))
            return nil
        }
        UserDefaults.standard.set(best, forKey: Self.scaleKey)
        log(String(format: "OBD: scale /%.2f confirmed (raw %.0f -> %.1f %%, Smartcar %.0f %%)", best, byte, byte / best, target))
        return best
    }
}
