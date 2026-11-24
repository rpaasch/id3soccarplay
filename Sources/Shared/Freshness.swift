//
//  Freshness.swift
//  ID3Maps — shared by app, widget and Intents extension.
//
//  One answer to "how old is this number?", used everywhere the SoC is shown or sent.
//  Two clocks matter:
//   * contactAt  – when we last reached the Worker (our own connection),
//   * measuredAt – when the car last reported to VW (or the dongle read it).
//  Parked and not charging, an old measuredAt is fine: the battery does not change. Driving or
//  charging, the car's value goes stale within minutes.
//

import Foundation

struct Freshness: Sendable {
    enum Level: Sendable { case fresh, aging, stale }

    let level: Level
    /// One short line for the app/widget, e.g. "Bilens tal fra kl. 08.38 (12 min gamle)".
    let text: String

    /// Max age of our own contact with the Worker before everything counts as stale.
    static let maxContactAge: TimeInterval = 10 * 60

    static func of(_ s: VehicleState, now: Date = Date()) -> Freshness {
        let contact = s.contactAt ?? s.measuredAt
        if now.timeIntervalSince(contact) > maxContactAge {
            return Freshness(level: .stale, text: "Ingen forbindelse siden \(clock(contact, now: now)) – tallet kan være forældet")
        }
        if s.obdLive == true {
            return Freshness(level: .fresh, text: "Live fra donglen")
        }
        let minutes = Int(now.timeIntervalSince(s.measuredAt) / 60)
        let moving = s.isCharging || s.driving == true
        guard moving else {
            return Freshness(level: .fresh, text: "Holder stille · bilen meldte \(clock(s.measuredAt, now: now))")
        }
        let what = s.isCharging ? "Lader" : "Kører"
        let age = minutes < 1 ? "lige nu" : "\(minutes) min gammelt"
        let level: Level = minutes <= 5 ? .fresh : (minutes <= 15 ? .aging : .stale)
        return Freshness(level: level, text: "\(what) · bilens tal fra \(clock(s.measuredAt, now: now)) (\(age))")
    }

    /// "kl. 08.38", "i går kl. 21.40" or "21/11 kl. 21.40".
    static func clock(_ d: Date, now: Date = Date()) -> String {
        let dk = Locale(identifier: "da_DK")
        let time = d.formatted(.dateTime.hour().minute().locale(dk))
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "kl. \(time)" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "i går kl. \(time)" }
        return "\(d.formatted(.dateTime.day().month(.defaultDigits).locale(dk))) kl. \(time)"
    }
}
