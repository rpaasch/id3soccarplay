//
//  VehicleState.swift
//  ID3Maps — shared.
//
//  The battery snapshot the extension reports to Maps. Comes from the Worker
//  (Smartcar) via `StatusClient`; M0's hard-coded 60 % is gone.
//

import Foundation

/// A point-in-time battery reading.
struct VehicleState: Sendable, Codable {
    /// 0.0–1.0.
    var stateOfCharge: Double
    /// Wall-clock time of the last *real* measurement.
    var measuredAt: Date
    var isCharging: Bool
    /// Remaining electric range in km, if known.
    var rangeKm: Double?
    /// Minutes to full while charging, if known.
    var minutesToFull: Int?
    /// Dynamic hints from the Worker (capacity, consumption, temperature). Optional:
    /// without them the baseline profile in id3.json is used unchanged.
    var model: ModelHints?
    /// "ac" or "dc" while charging, if known.
    var chargeKind: String?
    /// Charging power in W while charging (Smartcar's last value), if known.
    var chargePowerW: Double? = nil
    /// This charging session's measurements (for the live chart in the app).
    var chargeSamples: [ChargeSample]? = nil
    /// When the Worker last answered (we are in contact even if VW's value is minutes old).
    var contactAt: Date? = nil
    /// True when `stateOfCharge` is projected forward from VW's last value during a drive.
    var socEstimated: Bool? = nil
    /// The Worker's SoC projected to now while driving. Only Maps uses it; the app and the
    /// widget show the car's own reported value (so they match the dashboard).
    var socEstimate: Double? = nil
    /// True when the SoC came live from the OBD dongle.
    var obdLive: Bool? = nil
    /// The Worker's last error talking to VW/Smartcar (nil = fine).
    var workerError: String? = nil
}

/// One measurement of the current charging session.
struct ChargeSample: Codable, Sendable, Hashable {
    /// ms since 1970
    let t: Double
    /// 0...1
    let soc: Double
    let kw: Double
}
