//
//  EnergyCounter.swift
//  ID3Maps host app.
//
//  Battery energy counters found by the current hunt (28 Nov 2026): the first two bytes of the
//  BMS identifiers 1E2D and 1E2C fall while the car drives, and how fast they fall follows the
//  GPS road power closely (r = -0.94 and -0.91 over 16 pairs). Read as a counter, the fall per
//  second is the battery's real output: driving, heating and losses together.
//
//  The size of one count is not known and is not hard-coded. It is learnt from the display SoC:
//  Wh per count = SoC drop × usable capacity / counts used, summed over drives (a drive only
//  counts once the SoC has fallen at least 2 points). Until then the app shows counts, not kW.
//

import Foundation

struct EnergyCounter: Codable, Sendable {
    let did: String
    /// Calibrated stretches so far: counts used and the Wh the SoC drop says they were worth.
    var sumCounts = 0.0
    var sumWh = 0.0
    var drives = 0
    /// The current drive.
    var startSocPct: Double?
    var driveCounts = 0.0
    var lastValue: Int?
    var lastAt: Date?

    init(did: String) { self.did = did }

    /// Wh per count from earlier drives plus the current one (once it has a usable SoC drop).
    func whPerCount(socNow: Double?, capacityWh: Double) -> Double? {
        var c = sumCounts, wh = sumWh
        if let s0 = startSocPct, let s1 = socNow, s0 - s1 >= 2, driveCounts > 100 {
            c += driveCounts; wh += (s0 - s1) / 100 * capacityWh
        }
        guard c > 100, wh > 0 else { return nil }
        let v = wh / c
        return (0.05...50).contains(v) ? v : nil
    }

    /// Records a reading. Returns the counts used since the previous reading and the time between
    /// them, or nil for the first reading of a drive or a reading that makes no sense.
    mutating func record(raw: Int, at t: Date, socPct: Double?) -> (counts: Double, dt: Double)? {
        defer { lastValue = raw; lastAt = t }
        if startSocPct == nil, let s = socPct { startSocPct = s; driveCounts = 0 }
        guard let lv = lastValue, let la = lastAt, startSocPct != nil else { return nil }
        // The counter falls as energy is used; a 16-bit wrap is handled by the signed difference.
        let d = Double(Int16(truncatingIfNeeded: lv - raw))
        guard abs(d) < 8000 else { return nil }
        driveCounts += d      // standing still in between still counts: the counter is cumulative
        let dt = t.timeIntervalSince(la)
        return dt > 0 && dt < 120 ? (d, dt) : nil
    }

    /// End of a drive: keep the stretch for the calibration if the SoC fell enough.
    mutating func endDrive(socPct: Double?, capacityWh: Double) -> String? {
        defer { startSocPct = nil; driveCounts = 0; lastValue = nil; lastAt = nil }
        guard let s0 = startSocPct, let s1 = socPct else { return nil }
        let drop = s0 - s1
        guard drop >= 2, driveCounts > 100 else {
            return String(format: "OBD energy %@: drive not used for the scale (SoC %.1f → %.1f %%, %.0f counts)", did, s0, s1, driveCounts)
        }
        let wh = drop / 100 * capacityWh
        // Older drives weigh less, so a wrong early drive fades out.
        if drives >= 10 { sumCounts *= 0.8; sumWh *= 0.8 }
        sumCounts += driveCounts; sumWh += wh; drives += 1
        return String(format: "OBD energy %@: drive %.0f counts for SoC %.1f → %.1f %% (%.1f kWh) = %.2f Wh/count; scale now %.2f Wh/count (%d drives)",
                      did, driveCounts, s0, s1, wh / 1000, wh / driveCounts, sumWh / sumCounts, drives)
    }

    // MARK: Persistence

    private static let key = "energyCounters"

    static func load() -> [String: EnergyCounter] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let v = try? JSONDecoder().decode([String: EnergyCounter].self, from: d) else { return [:] }
        return v
    }

    static func save(_ v: [String: EnergyCounter]) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// One point of the battery-power chart.
struct PowerPoint: Sendable, Identifiable {
    let at: Date
    let kw: Double
    var id: Date { at }
}
