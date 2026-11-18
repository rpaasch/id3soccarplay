//
//  VehicleState.swift
//  ID3Maps — shared.
//
//  The battery snapshot the extension reports to Maps. In M0 this is HARD-CODED
//  (SoC 60 %). In M2 the provider will read the latest snapshot from the
//  Cloudflare Worker / App-Group cache and apply the estimation layer.
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

    /// Fixed M0 snapshot: 60 %, measured "2 minutes ago", not charging.
    static func hardcodedM0() -> VehicleState {
        VehicleState(
            stateOfCharge: 0.60,
            measuredAt: Date().addingTimeInterval(-120),
            isCharging: false,
            rangeKm: 255,          // ~0.60 * 425 WLTP, rough
            minutesToFull: nil
        )
    }
}
