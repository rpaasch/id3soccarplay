//
//  BusSurvey.swift
//  ID3Maps host app.
//
//  Looks beyond the battery controller: which other control units (ECUs) the car has on the
//  diagnostic bus and which values they give, so they can later feed the consumption model
//  (outside temperature from the car, heating/climate power, motor, odometer, …).
//
//  Read-only, through the same gate as everything else in OBDManager: only "AT…" settings for the
//  dongle and UDS ReadDataByIdentifier ("22" + 4 hex), only during a CarPlay drive, only while
//  the car is on (12 V ≥ 13 V) and moving.
//
//   1. Units: ask every 29-bit address 17FC00xx (answer on 17FE00xx) for its VW part number
//      (F187). Any answer, also a refusal, means a unit lives there.
//   2. Values: ask each unit for a list of identifiers, round robin over the units: first its
//      name (F19E) and the standard OBD values mapped to F4xx (speed, outside temperature,
//      coolant, battery, 12 V, odometer …), then the whole F4xx, 02xx–03xx and 2Axx ranges.
//   3. Tracking: values that change are read again in turn and stored with GPS speed,
//      acceleration and road energy. The report lists the standard values decoded and, for the
//      rest, how closely each follows speed and road power (and, for counters, its rate).
//
//  Progress and samples are kept in a file, so the survey continues across drives.
//

import Foundation

struct BusSurvey: Codable {
    struct Sample: Codable {
        let hex: String
        let v: Double
        let a: Double
        let t: Double
        let e: Double
    }

    /// The BMS, which OBDManager talks to by default (no header switch needed).
    static let homeEcu = "7B"
    static let maxSamples = 300

    /// Standard OBD values first (SAE J1979 PIDs as UDS F4xx), with the unit name (F19E) before them.
    static let priorityDIDs = ["F19E", "F446", "F40D", "F405", "F45B", "F442", "F4A6", "F431", "F41F", "F45C", "F40F", "F433", "F470"]

    /// Every identifier asked of each unit, in order.
    static let didList: [String] = {
        var out = priorityDIDs
        let seen = Set(priorityDIDs)
        for r in [0xF400...0xF4FF, 0x0200...0x03FF, 0x2A00...0x2AFF] {
            for d in r { let s = String(format: "%04X", d); if !seen.contains(s) { out.append(s) } }
        }
        return out
    }()

    // Stage 1
    var nextEcu: Int? = 0
    /// Unit address (2 hex) -> part number (or "?" when it answered without one).
    var ecus: [String: String] = [:]
    /// Unit address -> its name from F19E, when it gave one.
    var names: [String: String] = [:]

    // Stage 2
    var cursor: [String: Int] = [:]
    var ecuTurn = 0
    /// "ECU:DID" -> data length in bytes.
    var responders: [String: Int] = [:]

    // Stage 3
    var constant: Set<String> = []
    var samples: [String: [Sample]] = [:]
    var lastHex: [String: String] = [:]
    var trackIndex = 0
    var flip = false

    var unitsDone: Bool { nextEcu == nil }
    var valuesDone: Bool { ecus.keys.allSatisfy { (cursor[$0] ?? 0) >= Self.didList.count } }

    /// The next request: (unit, identifier, kind).
    enum Kind { case unit, value, track }
    mutating func next() -> (ecu: String, did: String, kind: Kind)? {
        if let n = nextEcu {
            nextEcu = n < 0xFF ? n + 1 : nil
            return (String(format: "%02X", n), "F187", .unit)
        }
        let tracked = trackedKeys
        flip.toggle()
        // Alternate between new identifiers and tracking once there is something to track.
        if (flip || valuesDone), !tracked.isEmpty {
            trackIndex = (trackIndex + 1) % tracked.count
            let parts = tracked[trackIndex].split(separator: ":")
            return (String(parts[0]), String(parts[1]), .track)
        }
        let units = ecus.keys.sorted().filter { (cursor[$0] ?? 0) < Self.didList.count }
        guard !units.isEmpty else { return nil }
        ecuTurn = (ecuTurn + 1) % units.count
        let ecu = units[ecuTurn]
        let i = cursor[ecu] ?? 0
        cursor[ecu] = i + 1
        return (ecu, Self.didList[i], .value)
    }

    var trackedKeys: [String] {
        responders.keys.filter { !constant.contains($0) && !$0.hasSuffix(":F19E") }.sorted()
    }

    // MARK: Recording

    mutating func recordUnit(ecu: String, reply: String) {
        let c = Self.compact(reply)
        guard c.contains("17FE00" + ecu) else { return }
        if let bytes = Self.message(reply: reply, ecu: ecu), bytes.count > 3, bytes[0] == 0x62 {
            ecus[ecu] = Self.ascii(Array(bytes.dropFirst(3)))
        } else {
            ecus[ecu] = "?"
        }
    }

    /// Records a value answer. Returns the data bytes (hex) on a positive answer.
    @discardableResult
    mutating func recordValue(ecu: String, did: String, reply: String, v: Double?, a: Double?, e: Double) -> String? {
        guard let bytes = Self.message(reply: reply, ecu: ecu), bytes.count >= 3, bytes[0] == 0x62,
              String(format: "%02X%02X", bytes[1], bytes[2]) == did else { return nil }
        let data = Array(bytes.dropFirst(3))
        let key = ecu + ":" + did
        if did == "F19E" { names[ecu] = Self.ascii(data); responders[key] = data.count; return nil }
        if responders[key] == nil { responders[key] = data.count }
        let hex = data.prefix(8).map { String(format: "%02X", $0) }.joined()
        lastHex[key] = hex
        guard !hex.isEmpty, let v, let a else { return hex }
        var list = samples[key] ?? []
        list.append(Sample(hex: hex, v: v, a: a, t: Date().timeIntervalSince1970, e: e))
        if list.count > Self.maxSamples { list.removeFirst(list.count - Self.maxSamples) }
        samples[key] = list
        if list.count >= 8, Set(list.map(\.hex)).count <= 1 { constant.insert(key) }
        return hex
    }

    // MARK: Parsing

    static func compact(_ reply: String) -> String {
        reply.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Reassembles the unit's ISO-TP answer from the dongle's lines (headers on): single frame
    /// "17FE00xx 0L …", first frame "17FE00xx 1L LL …", consecutive "17FE00xx 2n …".
    static func message(reply: String, ecu: String) -> [UInt8]? {
        let header = "17FE00" + ecu
        var out: [UInt8] = []
        var total: Int?
        for line in compact(reply).split(separator: "\n") where line.hasPrefix(header) {
            let body = Array(line.dropFirst(header.count))
            guard body.count >= 2, let pci = Int(String(body[0]), radix: 16) else { continue }
            var start = 2
            switch pci {
            case 0:
                guard let l = Int(String(body[1]), radix: 16) else { continue }
                total = l
            case 1:
                guard body.count >= 4, let l = Int(String(body[1...3]), radix: 16) else { continue }
                total = l; start = 4
            case 2: break
            default: continue
            }
            var i = start
            while i + 1 < body.count, let b = UInt8(String(body[i...i + 1]), radix: 16) { out.append(b); i += 2 }
        }
        guard let t = total, !out.isEmpty else { return nil }
        return Array(out.prefix(t))
    }

    static func ascii(_ b: [UInt8]) -> String {
        String(decoding: b.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Standard OBD value (F4xx = mode 01 PID xx) in plain words, or nil for other identifiers.
    static func standard(did: String, hex: String) -> (String, String)? {
        guard did.hasPrefix("F4"), let a = UInt32(hex.prefix(2), radix: 16) else { return nil }
        let ab = UInt32(hex.prefix(4), radix: 16).flatMap { hex.count >= 4 ? $0 : nil }
        switch did {
        case "F446": return ("Udetemperatur", "\(Int(a) - 40) °C")
        case "F40D": return ("Fart", "\(a) km/t")
        case "F405": return ("Kølevæske", "\(Int(a) - 40) °C")
        case "F40F": return ("Indsugningsluft", "\(Int(a) - 40) °C")
        case "F45C": return ("Olie/køling", "\(Int(a) - 40) °C")
        case "F45B": return ("HV-batteri", String(format: "%.1f %%", Double(a) * 100 / 255))
        case "F442": return ab.map { ("Styreenhedens spænding", String(format: "%.2f V", Double($0) / 1000)) }
        case "F431": return ab.map { ("Km siden fejlkoder slettet", "\($0) km") }
        case "F41F": return ab.map { ("Tid siden start", "\($0) s") }
        case "F433": return ("Lufttryk", "\(a) kPa")
        case "F4A6":
            guard hex.count >= 8, let v = UInt32(hex.prefix(8), radix: 16) else { return nil }
            return ("Kilometertæller", String(format: "%.1f km", Double(v) / 10))
        default: return nil
        }
    }

    // MARK: Report

    private static func readings(_ hex: String) -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let b = UInt8(hex.prefix(2), radix: 16) { out.append(("u8", Double(b))); out.append(("s8", Double(Int8(bitPattern: b)))) }
        return out + CurrentHunt.readings(hex)
    }

    func report(top: Int = 10) -> [String] {
        let asked = nextEcu ?? 256
        let didsAsked = ecus.keys.map { min(cursor[$0] ?? 0, Self.didList.count) }.reduce(0, +)
        var lines = [String(format: "OBD survey: %d/256 addresses, %d units, %d/%d identifiers asked, %d values (%d changing)",
                            asked, ecus.count, didsAsked, ecus.count * Self.didList.count,
                            responders.count, trackedKeys.count)]
        if !ecus.isEmpty {
            lines.append("OBD survey units: " + ecus.keys.sorted().map { e in
                "\(e)=\(names[e].map { "\($0) " } ?? "")\(ecus[e]!)"
            }.joined(separator: ", "))
        }
        for key in lastHex.keys.sorted() {
            let p = key.split(separator: ":")
            if let s = Self.standard(did: String(p[1]), hex: lastHex[key]!) {
                lines.append("OBD survey \(key) \(s.0): \(s.1)")
            }
        }
        // Changing values: how closely they follow road power / speed, and as counters.
        var found: [(String, Double)] = []
        for key in trackedKeys {
            guard let list = samples[key], list.count >= 8 else { continue }
            let power = list.map { CurrentHunt.roadPowerW(v: $0.v, a: $0.a) }
            let speed = list.map(\.v)
            let parsed = list.map { Self.readings($0.hex) }
            guard let kinds = parsed.first?.map(\.0) else { continue }
            var best: (String, Double)?
            for (i, name) in kinds.enumerated() {
                let vals = parsed.compactMap { $0.count > i ? $0[i].1 : nil }
                guard vals.count == list.count else { continue }
                let cp = CurrentHunt.pearson(vals, power) ?? 0
                let cs = CurrentHunt.pearson(vals, speed) ?? 0
                // Rate of change vs road power (counters).
                var xs: [Double] = [], ys: [Double] = []
                for k in 1..<list.count {
                    let dt = list[k].t - list[k - 1].t
                    guard dt >= 2, dt <= 400 else { continue }
                    xs.append((vals[k] - vals[k - 1]) / dt); ys.append((list[k].e - list[k - 1].e) / dt * 3600)
                }
                let cr = CurrentHunt.pearson(xs, ys) ?? 0
                let line = String(format: "OBD survey %@ %@: n %d, corr power %+.2f speed %+.2f rate %+.2f, %.0f…%.0f, last %@",
                                  key, name, list.count, cp, cs, cr, vals.min() ?? 0, vals.max() ?? 0, list.last?.hex ?? "")
                let score = max(abs(cp), abs(cs), abs(cr))
                if best == nil || score > best!.1 { best = (line, score) }
            }
            if let b = best { found.append(b) }
        }
        lines += found.sorted { $0.1 > $1.1 }.prefix(top).map(\.0)
        return lines
    }

    /// Short status for the app.
    var progress: String {
        if let n = nextEcu { return "leder efter styreenheder: \(n)/256, \(ecus.count) fundet" }
        let asked = ecus.keys.map { min(cursor[$0] ?? 0, Self.didList.count) }.reduce(0, +)
        let total = ecus.count * Self.didList.count
        return "\(ecus.count) styreenheder · \(responders.count) værdier · \(total > 0 ? asked * 100 / total : 100) % spurgt"
    }

    /// Values for the app: standard ones decoded, the rest as raw bytes.
    var shown: [(String, String)] {
        lastHex.keys.sorted().compactMap { key in
            let p = key.split(separator: ":")
            let unit = names[String(p[0])] ?? String(p[0])
            if let s = Self.standard(did: String(p[1]), hex: lastHex[key]!) { return ("\(s.0) (\(unit))", s.1) }
            guard !constant.contains(key) else { return nil }
            return ("\(unit) \(p[1])", lastHex[key]!)
        }
    }

    // MARK: Storage

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("bus_survey.json")
    }

    static func load() -> BusSurvey {
        guard let u = fileURL, let d = try? Data(contentsOf: u),
              let s = try? JSONDecoder().decode(BusSurvey.self, from: d) else { return BusSurvey() }
        return s
    }

    func save() {
        guard let u = Self.fileURL, let d = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }
}
