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
    var chargePowerScale: Double?
    var temperatureC: Double?
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
        if let implied = hints.consumptionKwhPer100,
           let baselineWhPerM = consumptionParams.mean(of: "vehicle_consumption_values_wh_per_m"),
           baselineWhPerM > 0 {
            // Wh per metre == kWh per km, so x100 gives kWh/100 km.
            let factor = min(1.5, max(0.8, implied / (baselineWhPerM * 100)))
            consumptionParams = consumptionParams.scalingArray("vehicle_consumption_values_wh_per_m", by: factor)
            notes.append(String(format: "consumption %.1f kWh/100km (x%.2f)", implied, factor))
        }

        // Charging power: baseline is for ~6 °C; the Worker supplies the temperature scale.
        if let scale = hints.chargePowerScale {
            let s = min(2.0, max(0.55, scale))
            chargeParams = chargeParams.scalingArray("vehicle_charge_axis_w", by: s)
            notes.append(String(format: "charge power x%.2f", s)
                + (hints.temperatureC.map { String(format: " (%.1f °C)", $0) } ?? ""))
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
