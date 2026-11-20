//
//  ProfileAdjuster.swift
//  ID3Maps — shared between app and Intents extension.
//
//  Adapts the baseline profile (id3.json) to what we know right now, using the
//  hints the Worker computes:
//
//   * capacity     – the real battery size from Smartcar's NominalCapacity;
//   * consumption  – the car's OWN range estimate (net kWh / (range / SoC)),
//                    which already reflects cold weather, HVAC and recent
//                    driving, so we don't have to model those ourselves;
//   * charging     – the baseline curve is calibrated to ~6 °C; the Worker
//                    scales it with the outdoor temperature.
//
//  Every factor is clamped so a bad reading can never produce an absurd profile,
//  and every hint is optional: missing hints leave the baseline untouched.
//

import Foundation

/// Hints as delivered by the Worker's `/status` (`model`).
struct ModelHints: Sendable, Codable {
    var capacityKwhNet: Double?
    var consumptionKwhPer100: Double?
    /// "learned" (real driving, from odometer + SoC) or "car-estimate".
    var consumptionSource: String?
    var learnedKm: Double?
    var chargePowerScale: Double?
    var temperatureC: Double?
    /// The temperature the baseline charging curve is calibrated for (scale x1.00).
    var referenceTempC: Double?
    /// Learned DC power (kW) at SoC 0, 10 … 100 % for the current temperature band;
    /// nil entries are not learned yet and fall back to baseline x scale.
    var chargeCurveKw: [Double?]?
    var chargeSessions: Int?
    /// True when the car was driven within the last ~45 min (battery warm).
    var batteryWarm: Bool?
    /// True when `chargeCurveKw` is the curve learned from warm-battery sessions.
    var chargeCurveWarm: Bool?
    /// 10 multipliers applied element-wise to Maps' consumption values (hypothesis: speed bins,
    /// slow -> fast). The mean is rescaled afterwards, so the shape only redistributes.
    var consumptionShape: [Double]?
    /// "physics", "learned" or a test mode.
    var consumptionShapeMode: String?
    /// Absolute consumption (kWh/100 km) for each of Maps' 10 speed bins (~20 km/h wide,
    /// confirmed by route tests). When present it replaces the vector; no mean rescaling.
    var consumptionBinsKwhPer100: [Double]?
    /// Auxiliary power (heating etc.) in W that Maps adds per hour of driving; replaces id3.json's 500 W.
    var auxPowerW: Double?
    /// When set, consumption is calibrated by your own trips (actual / physics prediction).
    var tripCalibration: TripCalibrationHint?
}

/// Mirror of the Worker's trip calibration, available to the extension too.
struct TripCalibrationHint: Codable, Sendable {
    let factor: Double
    let km: Double
    let n: Int
    let scope: String
}

extension JSONObject {
    /// Copy with every number in the array under `key` multiplied by `factor`.
    func scalingArray(_ key: String, by factor: Double) -> JSONObject {
        var f = fields
        if case .array(let items)? = f[key] {
            f[key] = .array(items.map { item in
                if case .number(let n) = item { return .number(n * factor) }
                return item
            })
        }
        return JSONObject(fields: f)
    }

    /// The numbers in the array under `key` (nil if absent or not all numeric).
    func numbers(_ key: String) -> [Double]? {
        guard case .array(let items)? = fields[key] else { return nil }
        var out: [Double] = []
        for item in items {
            guard case .number(let n) = item else { return nil }
            out.append(n)
        }
        return out
    }

    /// Copy with the array under `key` replaced by `values`.
    func replacingArray(_ key: String, with values: [Double]) -> JSONObject {
        var f = fields
        f[key] = .array(values.map { .number($0) })
        return JSONObject(fields: f)
    }

    /// Copy with the number under `key` replaced.
    func replacingNumber(_ key: String, with value: Double) -> JSONObject {
        var f = fields
        f[key] = .number(value)
        return JSONObject(fields: f)
    }

    /// Copy with the array under `key` multiplied element-wise by `factors` (same length only).
    func multiplyingArray(_ key: String, by factors: [Double]) -> JSONObject {
        guard let values = numbers(key), values.count == factors.count else { return self }
        return replacingArray(key, with: zip(values, factors).map { $0 * min(2.5, max(0.4, $1)) })
    }

    /// Mean of the numbers in the array under `key` (nil if absent/empty).
    func mean(of key: String) -> Double? {
        guard case .array(let items)? = fields[key] else { return nil }
        let nums = items.compactMap { item -> Double? in
            if case .number(let n) = item { return n }
            return nil
        }
        return nums.isEmpty ? nil : nums.reduce(0, +) / Double(nums.count)
    }
}

extension VehicleProfile {
    /// Learned power where we have it; elsewhere the baseline SHAPE anchored to the nearest
    /// learned bin (learned x baseline[i]/baseline[j]). Using the plain baseline there made a
    /// cliff, e.g. 65 kW learned at 70 % next to 30 kW cold-scaled baseline at 80 %.
    static func mergeCurve(learnedKw: [Double?], baselineW: [Double]) -> [Double] {
        let n = min(learnedKw.count, baselineW.count)
        let learned = (0..<n).compactMap { i in learnedKw[i].map { (i, min(250, max(5, $0)) * 1000) } }
        guard !learned.isEmpty else { return baselineW }
        return (0..<n).map { i in
            if let kw = learnedKw[i] { return min(250, max(5, kw)) * 1000 }
            let (j, wj) = learned.min { abs($0.0 - i) < abs($1.0 - i) }!
            guard baselineW[j] > 0 else { return baselineW[i] }
            return max(5000, min(250_000, wj * baselineW[i] / baselineW[j]))
        }
    }

    /// Returns the adapted profile and a one-line description for the log.
    func adjusted(with hints: ModelHints?) -> (profile: VehicleProfile, note: String) {
        guard let hints else { return (self, "baseline profile (no model hints)") }
        var notes: [String] = []

        // Capacity (also rescales the charging energy axes so they still end at "full").
        var battery = self.battery
        var chargeParams = chargingContract.vehicleParameters
        if let kwh = hints.capacityKwhNet, (40...100).contains(kwh) {
            let newWh = kwh * 1000
            let k = newWh / battery.usableCapacityWh
            if abs(k - 1) > 0.005 {
                battery = VehicleProfile.Battery(usableCapacityWh: newWh)
                chargeParams = chargeParams
                    .scalingArray("vehicle_energy_axis_wh", by: k)
                    .scalingArray("energy_w_per_h", by: k)
            }
            notes.append("capacity \(Int(kwh)) kWh")
        }

        // Consumption: scale the whole vector so its mean matches the car's own estimate.
        var consumptionParams = consumptionContract.vehicleParameters
        if let shape = hints.consumptionShape, shape.count == 10 {
            consumptionParams = consumptionParams.multiplyingArray("vehicle_consumption_values_wh_per_m", by: shape)
            notes.append("shape \(hints.consumptionShapeMode ?? "?")")
        }
        if let bins = hints.consumptionBinsKwhPer100, bins.count == 10 {
            // kWh/100 km -> Wh per metre is /100.
            consumptionParams = consumptionParams.replacingArray(
                "vehicle_consumption_values_wh_per_m", with: bins.map { min(0.6, max(0.05, $0 / 100)) })
            if let aux = hints.auxPowerW, (200...4000).contains(aux) {
                consumptionParams = consumptionParams.replacingNumber("vehicle_auxiliary_power_w", with: aux)
            }
            notes.append(String(format: "speed bins %@ (50: %.0f, 110: %.0f, 130: %.0f kWh/100km + aux %.0f W; mean %.1f)",
                                hints.consumptionShapeMode ?? "?", bins[2], bins[5], bins[6],
                                hints.auxPowerW ?? 500, hints.consumptionKwhPer100 ?? 0))
        } else if let implied = hints.consumptionKwhPer100,
           let baselineWhPerM = consumptionParams.mean(of: "vehicle_consumption_values_wh_per_m"),
           baselineWhPerM > 0 {
            // Wh per metre == kWh per km, so x100 gives kWh/100 km.
            // Winter consumption can be ~1.7x the baseline vector; a tighter clamp made Maps optimistic.
            let factor = min(2.0, max(0.7, implied / (baselineWhPerM * 100)))
            consumptionParams = consumptionParams.scalingArray("vehicle_consumption_values_wh_per_m", by: factor)
            let source = hints.consumptionSource == "learned"
                ? "learned over \(Int(hints.learnedKm ?? 0)) km" : "car estimate"
            notes.append(String(format: "consumption %.1f kWh/100km (x%.2f, ", implied, factor) + source + ")")
        }

        // Charging power: baseline is for ~6 °C; the Worker supplies the temperature scale.
        if let scale = hints.chargePowerScale {
            let s = min(2.0, max(0.55, scale))
            chargeParams = chargeParams.scalingArray("vehicle_charge_axis_w", by: s)
            notes.append(String(format: "charge power x%.2f", s)
                + (hints.temperatureC.map { String(format: " (%.1f °C)", $0) } ?? ""))
        }

        // Learned DC curve overrides the baseline per SoC decile where we have real data.
        if let curve = hints.chargeCurveKw, curve.count == 11,
           let base = chargeParams.numbers("vehicle_charge_axis_w"), base.count == 11 {
            let merged = VehicleProfile.mergeCurve(learnedKw: curve, baselineW: base)
            let learnedBins = curve.compactMap { $0 }.count
            chargeParams = chargeParams.replacingArray("vehicle_charge_axis_w", with: merged)
            let kind = hints.chargeCurveWarm == true ? "warm" : "cold"
            notes.append("charge curve learned, \(kind) battery (\(learnedBins)/11 bins, \(hints.chargeSessions ?? 0) sessions)")
        }

        let adjusted = VehicleProfile(
            vehicle: vehicle,
            battery: battery,
            range: range,
            connectors: connectors,
            consumptionContract: VehicleProfile.Contract(modelId: consumptionContract.modelId, vehicleParameters: consumptionParams),
            chargingContract: VehicleProfile.Contract(modelId: chargingContract.modelId, vehicleParameters: chargeParams)
        )
        return (adjusted, notes.isEmpty ? "baseline profile" : notes.joined(separator: ", "))
    }
}
