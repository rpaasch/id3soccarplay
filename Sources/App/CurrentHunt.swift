//
//  CurrentHunt.swift
//  ID3Maps
//
//  Looks for the battery controller value that carries the traction current, using read-only
//  requests during drives (OBDManager decides when a request may go out).
//
//   1. Discovery: ask every identifier 1E00…1EFF once and remember which ones answer.
//   2. Tracking: read the answering ones in turn, store each value with GPS speed and
//      acceleration, and drop values that never change.
//   3. Report: per identifier and reading (unsigned / signed, 2/3/4 bytes) the correlation with
//      a road-load power estimate from speed and acceleration. The traction current follows that
//      estimate closely (high when accelerating, negative when recuperating); a heater or 12 V
//      current does not.
//
//  Progress and samples are kept in a file, so the hunt continues across drives.
//

import Foundation

struct CurrentHunt: Codable {
    struct Sample: Codable {
        /// Data bytes after "62 DID" (hex, at most 4 bytes).
        let hex: String
        /// m/s and m/s².
        let v: Double
        let a: Double
        /// Wall clock (s since 1970) and the road energy (Wh) integrated from GPS since the app
        /// started, so pairs of samples give a mean road power over the interval. Optional: older
        /// stored samples have neither.
        var t: Double? = nil
        var e: Double? = nil
    }

    static let range = 0x1E00...0x1EFF
    static let maxSamples = 400

    /// Next identifier to try in discovery (nil once every one was asked).
    var nextDiscovery: Int? = range.lowerBound
    /// Identifier -> data length in bytes, for the ones that answered.
    var responders: [String: Int] = [:]
    /// Identifiers that never changed over enough samples (not worth more reads).
    var constant: Set<String> = []
    var samples: [String: [Sample]] = [:]
    var trackIndex = 0
    var discoveryLogged = false

    var discoveryDone: Bool { nextDiscovery == nil }

    /// Identifiers worth tracking. The 27 Nov discovery found 155 answering, of which 1E40…1EBD
    /// are ~126 two-byte values in a row (cell voltages / temperatures, not a pack current) and
    /// 1E05…1E29 one-byte values. Spread over all 155, each got only ~7 samples per drive and no
    /// report came out. A pack current needs at least 2 bytes with a sign, so track the
    /// multi-byte values plus the 2-byte ones before the cell block.
    var trackedDIDs: [String] {
        let focus = responders.filter { did, len in
            !constant.contains(did) && (len >= 3 || (len == 2 && did < "1E40"))
        }.keys.sorted()
        return focus.isEmpty ? responders.keys.filter { !constant.contains($0) }.sorted() : focus
    }

    /// The identifier to read next.
    mutating func nextDID() -> String? {
        if let n = nextDiscovery {
            nextDiscovery = n < Self.range.upperBound ? n + 1 : nil
            return String(format: "%04X", n)
        }
        let active = trackedDIDs
        guard !active.isEmpty else { return nil }
        trackIndex = (trackIndex + 1) % active.count
        return active[trackIndex]
    }

    /// Data bytes (hex) in a compact reply (headers on, spaces off), or nil if the identifier did
    /// not answer positively. Single frame: "<hdr>0N62DIDxx..", first frame: "<hdr>10LL62DIDxx..".
    static func payload(reply compact: String, did: String) -> String? {
        guard let r = compact.range(of: "62" + did) else { return nil }
        let before = compact[..<r.lowerBound]
        let after = String(compact[r.upperBound...])
        var dataBytes = 4
        if before.count >= 2, let pci = Int(before.suffix(2), radix: 16), pci >= 3, pci <= 7,
           !(before.count >= 4 && before.suffix(4).hasPrefix("1")) {
            dataBytes = pci - 3   // single frame: length covers 62 + DID + data
        } else if before.count >= 4, before.suffix(4).hasPrefix("1") {
            dataBytes = 3         // first frame of a longer answer: 3 data bytes in it
        }
        // Stop at a following frame header, if any.
        var data = after
        if let h = data.range(of: "17FE") { data = String(data[..<h.lowerBound]) }
        let n = min(dataBytes, 4, data.count / 2)
        guard n > 0 else { return "" }
        return String(data.prefix(n * 2))
    }

    /// Records the result of one request. `payload` nil = no positive answer.
    mutating func record(did: String, payload: String?, speedMs: Double?, accel: Double?,
                         at time: Date = Date(), roadEnergyWh: Double? = nil) {
        guard let p = payload else { return }
        if responders[did] == nil { responders[did] = p.count / 2 }
        guard !p.isEmpty, let v = speedMs, let a = accel else { return }
        var list = samples[did] ?? []
        list.append(Sample(hex: p, v: v, a: a, t: time.timeIntervalSince1970, e: roadEnergyWh))
        if list.count > Self.maxSamples { list.removeFirst(list.count - Self.maxSamples) }
        samples[did] = list
        if list.count >= 8, Set(list.map(\.hex)).count <= 1 { constant.insert(did) }
    }

    // MARK: Analysis

    /// Road-load power (W) for an ID.3 from speed and acceleration: mass x a, rolling resistance,
    /// air drag. Rough, but the shape is what matters for the correlation.
    static func roadPowerW(v: Double, a: Double) -> Double {
        v * (1900 * a + 180 + 0.38 * v * v)
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = Double(x.count)
        guard x.count >= 3, x.count == y.count else { return nil }
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (a, b) in zip(x, y) { sxy += (a - mx) * (b - my); sxx += (a - mx) * (a - mx); syy += (b - my) * (b - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Readings of the data bytes: name -> value.
    static func readings(_ hex: String) -> [(String, Double)] {
        var out: [(String, Double)] = []
        for bytes in [2, 3, 4] where hex.count >= bytes * 2 {
            guard let u = UInt64(hex.prefix(bytes * 2), radix: 16) else { continue }
            let full = Double(UInt64(1) << UInt64(bytes * 8))
            let uv = Double(u)
            out.append(("u\(bytes * 8)", uv))
            out.append(("s\(bytes * 8)", uv >= full / 2 ? uv - full : uv))
        }
        if hex.count >= 4, let b1 = UInt64(hex.dropFirst(2).prefix(4), radix: 16) {
            // Value starting at the second byte (first byte may be a status/flags byte).
            let v = Double(b1)
            out.append(("u16@1", v))
            out.append(("s16@1", v >= 32768 ? v - 65536 : v))
        }
        return out
    }

    struct Finding {
        let did: String
        let reading: String
        let n: Int
        let corrPower: Double
        let corrAccel: Double
        let corrSpeed: Double
        let minValue: Double
        let maxValue: Double
        let minHex: String
        let maxHex: String
        let distinct: Int
    }

    /// Best reading per identifier, strongest power correlation first.
    func findings(minSamples: Int = 8) -> [Finding] {
        var out: [Finding] = []
        let tracked = Set(trackedDIDs)
        for (did, list) in samples where list.count >= minSamples && tracked.contains(did) {
            let power = list.map { Self.roadPowerW(v: $0.v, a: $0.a) }
            let accel = list.map(\.a), speed = list.map(\.v)
            let parsed = list.map { Self.readings($0.hex) }
            guard let names = parsed.first?.map(\.0) else { continue }
            var best: Finding?
            for (i, name) in names.enumerated() {
                let vals = parsed.compactMap { $0.count > i && $0[i].0 == name ? $0[i].1 : nil }
                guard vals.count == list.count, let cp = Self.pearson(vals, power) else { continue }
                let lo = vals.indices.min { vals[$0] < vals[$1] }!, hi = vals.indices.max { vals[$0] < vals[$1] }!
                let f = Finding(did: did, reading: name, n: list.count, corrPower: cp,
                                corrAccel: Self.pearson(vals, accel) ?? 0, corrSpeed: Self.pearson(vals, speed) ?? 0,
                                minValue: vals[lo], maxValue: vals[hi], minHex: list[lo].hex, maxHex: list[hi].hex,
                                distinct: Set(vals).count)
                if best == nil || abs(cp) > abs(best!.corrPower) { best = f }
            }
            if let b = best { out.append(b) }
        }
        return out.sorted { abs($0.corrPower) > abs($1.corrPower) }
    }

    struct RateFinding {
        let did: String
        let reading: String
        let pairs: Int
        let corr: Double
        /// Value change per Wh of road energy (the counter's unit, if it is one).
        let perWh: Double
    }

    /// Counters: a cumulative energy or charge counter does not follow the power itself, its
    /// rate of change does. For consecutive samples of each identifier (2-400 s apart, same app
    /// run) correlate the value's change per second with the mean road power over the same
    /// interval. 1E3E (27/28 Nov) grew steadily from 137582 to 153541 and is the main suspect.
    func rateFindings(minPairs: Int = 6) -> [RateFinding] {
        var out: [RateFinding] = []
        for did in trackedDIDs {
            guard let list = samples[did], list.count >= minPairs + 1 else { continue }
            let parsed = list.map { Self.readings($0.hex) }
            guard let names = parsed.first?.map(\.0) else { continue }
            var best: RateFinding?
            for (i, name) in names.enumerated() {
                var xs: [Double] = [], ys: [Double] = [], dvSum = 0.0, deSum = 0.0
                for k in 1..<list.count {
                    let a = list[k - 1], b = list[k]
                    guard let ta = a.t, let tb = b.t, let ea = a.e, let eb = b.e else { continue }
                    let dt = tb - ta, de = eb - ea
                    guard dt >= 2, dt <= 400, de >= -50, de <= 2000,
                          parsed[k - 1].count > i, parsed[k].count > i,
                          parsed[k - 1][i].0 == name, parsed[k][i].0 == name else { continue }
                    let dv = parsed[k][i].1 - parsed[k - 1][i].1
                    xs.append(dv / dt); ys.append(de / dt * 3600)
                    dvSum += dv; deSum += de
                }
                guard xs.count >= minPairs, let c = Self.pearson(xs, ys) else { continue }
                let f = RateFinding(did: did, reading: name, pairs: xs.count, corr: c,
                                    perWh: deSum != 0 ? dvSum / deSum : 0)
                if best == nil || abs(c) > abs(best!.corr) { best = f }
            }
            if let b = best { out.append(b) }
        }
        return out.sorted { abs($0.corr) > abs($1.corr) }
    }

    /// Log lines: progress plus the strongest candidates.
    func report(top: Int = 8) -> [String] {
        let total = Self.range.count
        let asked = nextDiscovery.map { $0 - Self.range.lowerBound } ?? total
        let tracked = trackedDIDs
        let minN = tracked.map { samples[$0]?.count ?? 0 }.min() ?? 0
        var lines = [String(format: "OBD current hunt: %d/%d asked, %d answer, tracking %d (min %d samples each), %d constant",
                            asked, total, responders.count, tracked.count, minN, constant.count)]
        for f in findings().prefix(top) {
            lines.append(String(format: "OBD hunt %@ %@: n %d, corr power %+.2f accel %+.2f speed %+.2f, %.0f…%.0f (raw %@…%@), %d values",
                                f.did, f.reading, f.n, f.corrPower, f.corrAccel, f.corrSpeed,
                                f.minValue, f.maxValue, f.minHex, f.maxHex, f.distinct))
        }
        for r in rateFindings().prefix(5) {
            lines.append(String(format: "OBD hunt rate %@ %@: %d pairs, change/s vs road power corr %+.2f, %.3f per Wh",
                                r.did, r.reading, r.pairs, r.corr, r.perWh))
        }
        return lines
    }

    /// One line listing every identifier that answered and its data length.
    func respondersLine() -> String {
        let list = responders.keys.sorted().map { "\($0)(\(responders[$0]!)B)" }.joined(separator: " ")
        return "OBD current hunt: discovery done, \(responders.count) of \(Self.range.count) answer: \(list)"
    }

    // MARK: Storage

    private static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("current_hunt.json")
    }

    static func load() -> CurrentHunt {
        guard let u = fileURL, let d = try? Data(contentsOf: u),
              let h = try? JSONDecoder().decode(CurrentHunt.self, from: d) else { return CurrentHunt() }
        return h
    }

    func save() {
        guard let u = Self.fileURL, let d = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }
}
