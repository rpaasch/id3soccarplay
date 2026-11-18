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
}
