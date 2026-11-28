//
//  DriveLogView.swift
//  ID3Maps host app.
//
//  The Kørebog tab: all drives by month, a switch for work trips, totals in km and kroner,
//  an editor per drive, saved places, and export of the driving log for a month or a year.
//

import SwiftUI

struct DriveLogView: View {
    @State private var log = DriveLog.shared
    @State private var editing: DriveLogEntry?
    @State private var exportFile: ExportFile?
    @State private var onlyBusiness = false

    private var cal: Calendar { Calendar.current }

    private struct MonthGroup: Identifiable {
        let start: Date
        var entries: [DriveLogEntry]
        var id: Date { start }
    }

    private var months: [MonthGroup] {
        var out: [MonthGroup] = []
        for e in log.sorted where !onlyBusiness || e.business {
            let m = cal.dateInterval(of: .month, for: e.start)?.start ?? e.start
            if out.last?.start == m { out[out.count - 1].entries.append(e) } else { out.append(MonthGroup(start: m, entries: [e])) }
        }
        return out
    }

    private func businessKm(in interval: DateInterval?) -> Double {
        guard let i = interval else { return 0 }
        return log.entries.filter { $0.business && i.contains($0.start) }.map(\.km).reduce(0, +)
    }

    var body: some View {
        List {
            Section {
                summary
                Toggle("Vis kun tjenstlige ture", isOn: $onlyBusiness)
            }
            if months.isEmpty {
                Section {
                    Text("Ingen ture endnu. Hver tur, GPS'en måler, kommer automatisk her med tider, km og adresser. Du kan også tilføje en tur selv med +.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(months) { m in
                Section {
                    ForEach(m.entries) { e in
                        row(e)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = e }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { log.delete(e.id) } label: { Label("Slet", systemImage: "trash") }
                                if log.next(after: e) != nil {
                                    Button { log.mergeWithNext(e) } label: { Label("Læg sammen med næste", systemImage: "arrow.triangle.merge") }
                                        .tint(.indigo)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { var x = e; x.business.toggle(); log.update(x) } label: {
                                    Label(e.business ? "Privat" : "Tjenstlig", systemImage: e.business ? "house" : "briefcase")
                                }
                                .tint(e.business ? .gray : .teal)
                            }
                    }
                } header: {
                    HStack {
                        Text(m.start.formatted(.dateTime.month(.wide).year().locale(DK.locale)).capitalized(with: DK.locale))
                        Spacer()
                        let km = businessKm(in: cal.dateInterval(of: .month, for: m.start))
                        if km > 0 { Text("\(DK.num(km, 0)) km tjenstligt").monospacedDigit() }
                    }
                } footer: {
                    Button {
                        if let i = cal.dateInterval(of: .month, for: m.start) {
                            export(i, title: m.start.formatted(.dateTime.month(.wide).year().locale(DK.locale)))
                        }
                    } label: {
                        Label("Eksportér kørselsregnskab for måneden", systemImage: "square.and.arrow.up")
                    }
                    .font(.footnote)
                }
            }
            settingsSection
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = log.addManual() } label: { Label("Tilføj tur", systemImage: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    if let i = cal.dateInterval(of: .year, for: .now) {
                        export(i, title: String(cal.component(.year, from: .now)))
                    }
                } label: { Label("Eksportér hele året", systemImage: "square.and.arrow.up.on.square") }
            }
        }
        .sheet(item: $editing) { e in
            DriveEditor(entry: e).presentationDetents([.large])
        }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
    }

    private var summary: some View {
        let month = businessKm(in: cal.dateInterval(of: .month, for: .now))
        let year = businessKm(in: cal.dateInterval(of: .year, for: .now))
        return HStack(spacing: 12) {
            total("denne måned", km: month)
            Divider()
            total("i år", km: year)
        }
        .padding(.vertical, 4)
    }

    private func total(_ label: String, km: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(DK.num(km, 0)) km").font(.title2.bold()).monospacedDigit()
            Text("\(DK.num(km * log.rate, 0)) kr. · tjenstligt \(label)").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ e: DriveLogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: e.business ? "briefcase.fill" : "car")
                .foregroundStyle(e.business ? Color.teal : Color.secondary)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(e.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(DK.locale))) · \(DK.time(e.start))–\(DK.time(e.end))")
                    .font(.subheadline.weight(.semibold))
                Text("\(e.fromText.isEmpty ? "ukendt start" : e.fromText) → \(e.toText.isEmpty ? "ukendt mål" : e.toText)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                if e.business {
                    Text(e.purpose.isEmpty ? "Formål mangler" : e.purpose)
                        .font(.caption)
                        .foregroundStyle(e.purpose.isEmpty ? Color.orange : Color.primary)
                }
            }
            Spacer(minLength: 8)
            Text("\(DK.num(e.km, 1)) km").font(.callout.weight(.semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tryk for at redigere")
    }

    private var settingsSection: some View {
        Section {
            TextField("Dit navn (står på eksporten)", text: Binding(get: { log.driverName }, set: { log.setDriverName($0) }))
            HStack {
                Text("Sats")
                Spacer()
                TextField("kr/km", value: Binding(get: { log.rate }, set: { log.setRate($0) }),
                          format: .number.precision(.fractionLength(2)).locale(DK.locale))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                Text("kr/km").foregroundStyle(.secondary)
            }
            ForEach(log.places) { p in
                VStack(alignment: .leading) {
                    Text(p.name)
                    if !p.address.isEmpty { Text(p.address).font(.caption).foregroundStyle(.secondary) }
                }
                .swipeActions { Button(role: .destructive) { log.deletePlace(p.id) } label: { Label("Slet", systemImage: "trash") } }
            }
        } header: {
            Text("Indstillinger og steder")
        } footer: {
            Text("Tjek satsen hvert år hos din arbejdsgiver eller Skat. Steder gemmer du fra en tur (fx \"Arbejde\"); ture, der starter eller slutter inden for 200 m, får stedets navn. Positionerne bliver på telefonen og sendes aldrig til Workeren. Adresser slås op hos Apple.")
        }
    }

    private func export(_ i: DateInterval, title: String) {
        let text = log.csv(from: i.start, to: i.end, title: title)
        let safe = title.replacingOccurrences(of: " ", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("koerselsregnskab-\(safe).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportFile = ExportFile(url: url)
        } catch {
            SharedLog.shared.log("Kørebog export failed: \(error)", category: "app")
        }
    }
}

/// Edit one drive: work trip or not, purpose, addresses, km and times.
private struct DriveEditor: View {
    @State var entry: DriveLogEntry
    @Environment(\.dismiss) private var dismiss
    @State private var naming: Bool? = nil      // true = start, false = destination
    @State private var placeName = ""

    private let log = DriveLog.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $entry.business) { Label("Tjenstlig kørsel", systemImage: "briefcase") }
                    if entry.business {
                        TextField("Formål (fx møde på Rådhuset)", text: $entry.purpose, axis: .vertical)
                        let recent = log.recentPurposes.filter { $0 != entry.purpose }
                        if !recent.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(recent, id: \.self) { p in
                                    Button(p) { entry.purpose = p }
                                        .font(.caption).buttonStyle(.bordered).buttonBorderShape(.capsule)
                                }
                            }
                        }
                    }
                }
                Section("Rute") {
                    LabeledContent("Fra") { TextField("Startadresse", text: $entry.fromText).multilineTextAlignment(.trailing) }
                    if entry.from != nil { Button("Gem start som sted…") { placeName = ""; naming = true }.font(.caption) }
                    LabeledContent("Til") { TextField("Mål", text: $entry.toText).multilineTextAlignment(.trailing) }
                    if entry.to != nil { Button("Gem mål som sted…") { placeName = ""; naming = false }.font(.caption) }
                    LabeledContent("Km") {
                        TextField("km", value: $entry.km, format: .number.precision(.fractionLength(1)).locale(DK.locale))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                Section("Tid") {
                    DatePicker("Start", selection: $entry.start)
                    DatePicker("Slut", selection: $entry.end, in: entry.start...)
                }
                if entry.business {
                    Section {
                        LabeledContent("Godtgørelse", value: "\(DK.num(entry.km * log.rate, 2)) kr.")
                    } footer: {
                        Text("\(DK.num(entry.km, 1)) km × \(DK.num(log.rate, 2)) kr/km")
                    }
                }
                Section {
                    Button("Slet turen", role: .destructive) { log.delete(entry.id); dismiss() }
                }
            }
            .navigationTitle(entry.manual ? "Tur (tilføjet selv)" : "Tur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Gem") { log.update(entry); dismiss() } }
            }
            .alert("Navn på stedet", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("fx Arbejde", text: $placeName)
                Button("Gem") {
                    let start = naming == true
                    if let p = start ? entry.from : entry.to, !placeName.trimmingCharacters(in: .whitespaces).isEmpty {
                        let name = placeName.trimmingCharacters(in: .whitespaces)
                        log.savePlace(name: name, address: start ? entry.fromText : entry.toText, at: p)
                        if start { entry.fromText = name } else { entry.toText = name }
                    }
                    naming = nil
                }
                Button("Annullér", role: .cancel) { naming = nil }
            } message: {
                Text("Ture, der starter eller slutter her, får dette navn i kørebogen.")
            }
        }
    }
}
