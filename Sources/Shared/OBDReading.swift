//
//  OBDReading.swift
//  ID3Maps — shared between app and Intents extension.
//
//  A state-of-charge value read live from the car's battery management system through the
//  Bluetooth OBD dongle (by the host app). The extension prefers it over the cloud value
//  (2-5 min old) when it is fresh AND validated against the cloud value, so a misread
//  diagnostic value can never mislead Maps.
//

import Foundation

struct OBDReading: Codable, Sendable {
    /// 0.0-1.0
    var soc: Double
    var at: Date
    /// True once the scaling of this value was confirmed against the Smartcar SoC.
    var validated: Bool

    /// Maximum age for Maps to use it (the dongle is polled every ~5 s while the car is on).
    static let maxAge: TimeInterval = 60

    var isFreshAndValid: Bool { validated && Date().timeIntervalSince(at) < Self.maxAge }
}
