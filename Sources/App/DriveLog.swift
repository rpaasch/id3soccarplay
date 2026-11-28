//
//  DriveLog.swift
//  ID3Maps host app.
//
//  Kørebog: every drive the GPS records becomes an entry with date, times, km and start/end
//  address. Mark the work trips ("tjenstlig"), add the purpose, and export a driving log
//  (kørselsregnskab) as a spreadsheet file for the employer / Skat.
//
//  Privacy: positions are stored on the phone only and are never sent to the Worker. Turning
//  them into street addresses uses Apple's geocoder (as Apple Maps does); saved places
//  ("Arbejde", "Hjem") are matched on the phone without any network.
//

import Foundation
import CoreLocation
import Observation

struct LogPlace: Codable, Sendable, Hashable {
    var lat: Double
    var lon: Double

    func distance(to o: LogPlace) -> Double {
        CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: o.lat, longitude: o.lon))
    }
}

struct DriveLogEntry: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date
    var km: Double
    var from: LogPlace?
    var to: LogPlace?
    /// Address or place name shown in the log (editable).
    var fromText = ""
    var toText = ""
    var business = false
    var purpose = ""
    var manual = false
}

struct SavedPlace: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var place: LogPlace
}

@MainActor
@Observable
final class DriveLog {
    static let shared = DriveLog()

    private(set) var entries: [DriveLogEntry] = []
    private(set) var places: [SavedPlace] = []
    /// Kilometre rate for the export (kr/km). Editable: it changes every year.
    private(set) var rate: Double = 3.81
    private(set) var driverName = ""

    func setRate(_ v: Double) { guard v >= 0, v < 100 else { return }; rate = v; save() }
    func setDriverName(_ v: String) { driverName = v; save() }

    private struct Stored: Codable {
        var entries: [DriveLogEntry]
        var places: [SavedPlace]
        var rate: Double
        var driverName: String
    }


    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drivelog.json")
    }

    private init() {
        if let d = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            entries = s.entries; places = s.places; rate = s.rate; driverName = s.driverName
        }
    }

    private func save() {
        let s = Stored(entries: entries, places: places, rate: rate, driverName: driverName)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    // MARK: Entries

    var sorted: [DriveLogEntry] { entries.sorted { $0.start > $1.start } }

    /// A GPS segment ended: log it and look up the addresses.
    func addDrive(start: Date, end: Date, km: Double, from: LogPlace?, to: LogPlace?) {
        var e = DriveLogEntry(start: start, end: end, km: (km * 10).rounded() / 10, from: from, to: to)
        e.fromText = from.flatMap(savedName) ?? ""
        e.toText = to.flatMap(savedName) ?? ""
        // A trip starting where the last work trip ended (within 15 min) is probably its continuation.
        if let last = sorted.first, last.business, start.timeIntervalSince(last.end) < 15 * 60 {
            e.business = true; e.purpose = last.purpose
        }
        entries.append(e)
        save()
        SharedLog.shared.log(String(format: "Kørebog: drive %.1f km logged", e.km), category: "drive")
        Task { await fillAddresses(e.id) }
    }

    func addManual() -> DriveLogEntry {
        let now = Date()
        let e = DriveLogEntry(start: now.addingTimeInterval(-1800), end: now, km: 0, business: true, manual: true)
        entries.append(e)
        save()
        return e
    }

    func update(_ e: DriveLogEntry) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        entries[i] = e
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// The drive that came right after this one (in time), if any.
    func next(after e: DriveLogEntry) -> DriveLogEntry? {
        entries.filter { $0.start > e.start }.min { $0.start < $1.start }
    }

    /// Joins a drive with the next one (e.g. a trip split by a charging stop).
    func mergeWithNext(_ e: DriveLogEntry) {
        guard let n = next(after: e), var first = entries.first(where: { $0.id == e.id }) else { return }
        first.end = n.end
        first.km = ((first.km + n.km) * 10).rounded() / 10
        first.to = n.to
        first.toText = n.toText
        first.business = first.business || n.business
        if first.purpose.isEmpty { first.purpose = n.purpose }
        entries.removeAll { $0.id == n.id }
        update(first)
    }

    /// Purposes used before, most recent first (quick picks in the editor).
    var recentPurposes: [String] {
        var seen = Set<String>(), out: [String] = []
        for e in sorted where !e.purpose.isEmpty && seen.insert(e.purpose).inserted { out.append(e.purpose) }
        return Array(out.prefix(6))
    }

    // MARK: Places

    private func savedName(_ p: LogPlace) -> String? {
        places.filter { $0.place.distance(to: p) < 200 }
            .min { $0.place.distance(to: p) < $1.place.distance(to: p) }?.name
    }

    func savePlace(name: String, address: String, at p: LogPlace) {
        places.removeAll { $0.place.distance(to: p) < 50 }
        places.append(SavedPlace(name: name, address: address, place: p))
        // Entries that start or end there get the name.
        for i in entries.indices {
            if let f = entries[i].from, f.distance(to: p) < 200 { entries[i].fromText = name }
            if let t = entries[i].to, t.distance(to: p) < 200 { entries[i].toText = name }
        }
        save()
    }

    func deletePlace(_ id: UUID) {
        places.removeAll { $0.id == id }
        save()
    }

    private func fillAddresses(_ id: UUID) async {
        for which in [true, false] {
            guard let e = entries.first(where: { $0.id == id }) else { return }
            let text = which ? e.fromText : e.toText
            guard text.isEmpty, let p = which ? e.from : e.to else { continue }
            guard let a = await address(for: p) else { continue }
            guard var cur = entries.first(where: { $0.id == id }) else { return }
            if which { if cur.fromText.isEmpty { cur.fromText = a } } else if cur.toText.isEmpty { cur.toText = a }
            update(cur)
        }
    }

    /// "Vejnavn 12, 4130 Viby Sj." from Apple's geocoder (its handler runs on the main thread).
    func address(for p: LogPlace) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: p.lat, longitude: p.lon),
                                                preferredLocale: Locale(identifier: "da_DK")) { marks, _ in
                cont.resume(returning: marks?.first.flatMap(Self.format))
            }
        }
    }

    nonisolated private static func format(_ m: CLPlacemark) -> String? {
        let street = [m.thoroughfare, m.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        let town = [m.postalCode, m.locality].compactMap { $0 }.joined(separator: " ")
        let s = [street, town].filter { !$0.isEmpty }.joined(separator: ", ")
        return s.isEmpty ? m.name : s
    }

    // MARK: Export

    /// Kørselsregnskab for the business trips in [from, to): semicolon-separated for Danish
    /// Excel/Numbers, decimal commas, with totals.
    func csv(from: Date, to: Date, title: String) -> String {
        let rows = entries.filter { $0.business && $0.start >= from && $0.start < to }.sorted { $0.start < $1.start }
        let dk = Locale(identifier: "da_DK")
        func num(_ v: Double, _ d: Int) -> String { v.formatted(.number.precision(.fractionLength(d)).grouping(.never).locale(dk)) }
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = ["Kørselsregnskab – tjenstlig kørsel", "Periode;\(cell(title))"]
        if !driverName.isEmpty { out.append("Navn;\(cell(driverName))") }
        out.append("Køretøj;VW ID.3")
        out.append("")
        out.append("Dato;Start;Slut;Fra;Til;Formål;Km;Sats (kr/km);Beløb (kr)")
        var km = 0.0
        for e in rows {
            km += e.km
            out.append([e.start.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().locale(dk)),
                        e.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(dk)),
                        e.end.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(dk)),
                        cell(e.fromText), cell(e.toText), cell(e.purpose),
                        num(e.km, 1), num(rate, 2), num(e.km * rate, 2)].joined(separator: ";"))
        }
        out.append("")
        out.append("I alt;;;;;;\(num(km, 1));;\(num(km * rate, 2))")
        out.append("")
        out.append("Km er målt med iPhonens GPS. \(rows.count) ture.")
        return "\u{FEFF}" + out.joined(separator: "\r\n") + "\r\n"
    }
}
