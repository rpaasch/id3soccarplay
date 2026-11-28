//
//  DashboardViews.swift
//  ID3Maps host app.
//
//  Reusable visual building blocks for the redesigned app: cards, the battery ring, status
//  chips, a small bar chart for Maps' speed bins and a trip card. Everything is plain SwiftUI,
//  supports Dynamic Type and dark mode, and combines elements for VoiceOver.
//

import SwiftUI
import Charts

/// A rounded card with an optional title and SF Symbol.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    /// The longer explanation, behind an ⓘ button in the title row instead of on the card.
    var info: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    Label(title, systemImage: symbol ?? "circle")
                        .font(.fig(.subheadline, .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let info { InfoButton(text: info) }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A small ⓘ that shows an explanation in a popover, so the screens stay light.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "info.circle")
                .font(.fig(.body))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Forklaring")
        .accessibilityHint(text)
        .popover(isPresented: $shown) {
            Text(text)
                .font(.fig(.callout))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Key/value row used inside cards.
struct KeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }
        .font(.fig(.callout))
        .accessibilityElement(children: .combine)
    }
}

/// The big state of charge: number, small "%", and a slim bar (same look as the widget;
/// a ring could not hold "100" without the digits hitting the edge).
struct BatteryRing: View {
    let soc: Double          // 0...1
    let charging: Bool

    private var color: Color {
        switch soc {
        case ..<0.15: return .red
        case ..<0.30: return .orange
        default: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int((soc * 100).rounded()))")
                    .font(.fig(size: 60, weight: .bold))
                    .monospacedDigit()
                Text("%").font(.fig(size: 26, weight: .semibold)).foregroundStyle(.secondary)
                if charging {
                    Image(systemName: "bolt.fill").font(.fig(size: 24, weight: .semibold)).foregroundStyle(.yellow)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.22))
                    Capsule().fill(color.gradient).frame(width: max(8, g.size.width * min(1, max(0, soc))))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.6), value: soc)
        }
        .frame(width: 160, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Batteri \(Int((soc * 100).rounded())) procent\(charging ? ", lader" : "")")
    }
}

/// Lays its children out left to right and wraps to a new line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let w = rows.map(\.width).max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, w) } ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? size.width : cur.width + spacing + size.width
            if add > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = Row(items: [i], width: size.width, height: size.height)
            } else {
                cur.items.append(i); cur.width = add; cur.height = max(cur.height, size.height)
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

/// Small capsule showing a status.
struct StatusChip: View {
    let text: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.fig(.caption, .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Consumption per speed bin as small bars: kWh/100 km incl. heating (what Maps uses), or kW
/// per hour with a bar for standing still (what the car draws).
struct SpeedBinsChart: View {
    let bins: [Double]       // 10 bins, traction only
    let auxW: Double
    /// Part of auxW that is only the cold-start extra (first ~15 min of a cold car).
    var coldW: Double = 0

    /// One segment of a stacked bar: driving (wheels) or heating, per speed.
    private struct Part: Identifiable {
        let id: String
        let label: String
        let kind: String
        let kwh: Double
        let total: Double
        let top: Bool
    }

    static let mids = [10.0, 30, 50, 70, 90, 110, 130, 150]
    static let drivingLabel = "Kørsel"
    static let heatingLabel = "Varme"
    static let coldLabel = "Koldstart"

    /// kWh/100 km at speed bin `i` including heating (aux power spread over the km driven).
    static func value(bins: [Double], auxW: Double, index i: Int) -> Double {
        bins[i] + heating(auxW: auxW, index: i)
    }

    /// Heating's share per 100 km: the same kW, but the slower you go, the longer each km takes.
    static func heating(auxW: Double, index i: Int) -> Double { auxW / 1000 / mids[i] * 100 }

    /// What the bars show: energy per distance (what Maps uses) or power per hour (what the car draws).
    enum Unit: String, CaseIterable, Identifiable {
        case perKm = "pr. 100 km"
        case perHour = "pr. time"
        var id: String { rawValue }
    }
    @State private var unit: Unit = .perKm

    /// How long the cold-start extra lasts (the Worker's WARMUP_H).
    static let warmupHours = 0.25

    private var parts: [Part] {
        unit == .perKm ? perKmParts : perHourParts
    }

    /// kWh/100 km: heating spread over the km, so slow speeds carry a big share of it.
    private var perKmParts: [Part] {
        Self.mids.indices.flatMap { i -> [Part] in
            let label = "\(Int(Self.mids[i]))"
            let drive = bins[i]
            let cold = Self.heating(auxW: coldW, index: i)
            let heat = Self.heating(auxW: auxW - coldW, index: i)
            let total = drive + heat + cold
            var out = [
                Part(id: "\(i)d", label: label, kind: Self.drivingLabel, kwh: drive, total: total, top: false),
                Part(id: "\(i)h", label: label, kind: Self.heatingLabel, kwh: heat, total: total, top: coldW <= 0),
            ]
            if coldW > 0 {
                out.append(Part(id: "\(i)c", label: label, kind: Self.coldLabel, kwh: cold, total: total, top: true))
            }
            return out
        }
    }

    /// kW: heating is the same band at every speed, standing still included; driving grows on top.
    /// The cold-start extra is a one-off per trip, so it is not in these bars (see the note).
    private var perHourParts: [Part] {
        let heat = max(0, auxW - coldW) / 1000
        // Heating first in every bar, so it is the bottom band and standing still is just that band.
        let still = [Part(id: "0h", label: "0", kind: Self.heatingLabel, kwh: heat, total: heat, top: true)]
        return still + Self.mids.indices.flatMap { i -> [Part] in
            let label = "\(Int(Self.mids[i]))"
            let drive = bins[i] / 100 * Self.mids[i]
            let total = drive + heat
            return [
                Part(id: "\(i)h", label: label, kind: Self.heatingLabel, kwh: heat, total: total, top: false),
                Part(id: "\(i)d", label: label, kind: Self.drivingLabel, kwh: drive, total: total, top: true),
            ]
        }
    }

    private func totalText(_ v: Double) -> String {
        unit == .perHour && v < 10 ? DK.num(v, 1) : "\(Int(v.rounded()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(unit == .perKm ? "kWh pr. 100 km ved hver fart" : "kW, bilen bruger ved hver fart")
                    .font(.fig(.caption2)).foregroundStyle(.secondary)
                InfoButton(text: note)
                Spacer(minLength: 8)
                Picker("Vis", selection: $unit) {
                    ForEach(Unit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .fixedSize()
            }
            Chart(parts) { p in
                BarMark(x: .value("km/t", p.label), y: .value(unit == .perKm ? "kWh/100 km" : "kW", p.kwh), width: .ratio(0.6))
                    .foregroundStyle(by: .value("Del", p.kind))
                    .annotation(position: .top, spacing: 2) {
                        if p.top {
                            Text(totalText(p.total)).font(.fig(.caption2).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
            }
            .chartForegroundStyleScale([Self.drivingLabel: Color.teal, Self.heatingLabel: Color.orange,
                                        Self.coldLabel: Color.orange.opacity(0.45)])
            .chartLegend(position: .top, alignment: .leading, spacing: 10)
            // Headroom above the tallest bar so its number never runs into the legend.
            .chartYScale(domain: 0...((parts.map(\.total).max() ?? 1) * 1.2))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.fig(.caption2)) }
            }
            .frame(height: 130)
            .animation(.easeInOut(duration: 0.25), value: unit)
            Text("km/t").font(.fig(.caption2)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            if coldW > 0 {
                Label("Kold bil: +\(DK.num(coldW / 1000, 1)) kW de første 15 min", systemImage: "snowflake")
                    .font(.fig(.caption2)).foregroundStyle(.cyan)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(unit == .perKm
            ? "Forbrug pr. 100 km efter fart, som Maps regner med, delt i kørsel og varme"
            : "Effekt i kilowatt efter fart, delt i kørsel og varme. Varmen er den samme, også når bilen holder stille")
    }

    private var note: String {
        let steady = max(0, auxW - coldW) / 1000
        var s: String
        if unit == .perKm {
            s = "Det er de tal, Maps regner rækkevidde med. Varmen bruger ca. \(DK.num(steady, 1)) kW, uanset fart. Kører du langsomt, tager hver km længere tid, så varmen fylder meget pr. km. Det er tiden, ikke farten, der koster ved lav fart. Skift til \"pr. time\" for at se det."
            if coldW > 0 {
                s += " Bilen er kold lige nu, så Maps får \(DK.num(coldW / 1000, 1)) kW ekstra, til den er varmet op (ca. de første 15 min)."
            }
        } else {
            s = "Varmen koster det samme hver time, også når bilen holder stille (\(DK.num(steady, 1)) kW). Kørslen kommer oven i og vokser med farten. Ved 10 km/t bruger bilen ca. \(DK.num(bins[0] / 10 + steady, 1)) kW i alt."
            if coldW > 0 {
                s += " Koldstart er en engangsudgift: ca. \(DK.num(coldW / 1000 * Self.warmupHours, 1)) kWh de første 15 min af turen, når bilen har holdt stille i over en time."
            }
        }
        return s
    }
}

/// Danish formatting regardless of the phone's language.
enum DK {
    static let locale = Locale(identifier: "da_DK")
    static func num(_ v: Double, _ decimals: Int = 1) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).locale(locale))
    }
    static func time(_ d: Date) -> String { d.formatted(.dateTime.hour().minute().locale(locale)) }
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "I dag" }
        if cal.isDateInYesterday(d) { return "I går" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale)).capitalized(with: locale)
    }
}

/// One trip: when, how far, and what it used compared with what Maps was told.
struct TripCard: View {
    let trip: Trip
    /// Shared bar scale (kWh/100 km) so trips can be compared with each other.
    let scale: Double

    private var tint: Color {
        guard trip.isCounted else { return .gray }
        switch trip.vsMaps {
        case ..<0.92: return .blue
        case ..<1.08: return .green
        case ..<1.2: return .orange
        default: return .red
        }
    }

    private var verdict: String {
        guard trip.isCounted else {
            return trip.km < 20
                ? "For kort til at tælle med"
                : "Tæller ikke med – målingen ser forkert ud"
        }
        let pct = Int(((trip.vsMaps - 1) * 100).rounded())
        switch trip.vsMaps {
        case ..<0.95: return "Brugte \(-pct) % mindre end Maps regnede med"
        case ..<1.05: return "Som Maps regnede med"
        default: return "Brugte \(pct) % mere end Maps regnede med"
        }
    }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(DK.time(trip.startDate))–\(DK.time(trip.endDate))")
                        .font(.fig(.headline)).monospacedDigit()
                    Text("\(trip.minutes) min" + ((trip.joined ?? 1) > 1 ? " · med kort stop" : ""))
                        .font(.fig(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Text((trip.vsMaps >= 1 ? "+" : "−") + DK.num(abs(trip.vsMaps - 1) * 100, 0) + " %")
                    .font(.fig(.subheadline, .bold)).monospacedDigit()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(tint)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { stats }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) { distanceStats }
                    HStack(spacing: 12) { conditionStats }
                }
            }
            .font(.fig(.caption)).foregroundStyle(.secondary)

            VStack(spacing: 6) {
                bar("Brugte", trip.kwhPer100, trip.isCounted ? .primary : .secondary)
                bar("Maps", trip.mapsValue, .teal)
            }
            .padding(.top, 2)

            HStack(spacing: 6) {
                if trip.cold == true { Image(systemName: "snowflake").foregroundStyle(.cyan) }
                Text(verdict).foregroundStyle(trip.isCounted ? tint : .secondary)
            }
            .font(.fig(.caption))
        }
        .opacity(trip.isCounted ? 1 : 0.75)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var stats: some View { distanceStats; conditionStats }

    @ViewBuilder private var distanceStats: some View {
        stat("road.lanes", "\(DK.num(trip.km, 0)) km")
        stat("battery.50", "\(DK.num(trip.socFrom * 100, 0))→\(DK.num(trip.socTo * 100, 0)) %")
    }

    @ViewBuilder private var conditionStats: some View {
        if let t = trip.tempC { stat("thermometer.medium", "\(DK.num(t, 0)) °C") }
        if let v = trip.avgKmh { stat("speedometer", "\(DK.num(v, 0)) km/t") }
    }

    private func stat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).monospacedDigit()
        }
        .fixedSize()
    }

    private func bar(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.fig(.caption)).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(6, g.size.width * min(1, value / max(scale, 1))))
                }
            }
            .frame(height: 8)
            Text(DK.num(value)).font(.fig(.caption).monospacedDigit()).frame(width: 36, alignment: .trailing)
        }
    }
}

/// The shared log on its own page.
struct LogView: View {
    let entries: [LogEntry]
    var body: some View {
        List {
            if entries.isEmpty {
                Text("Ingen linjer endnu.").foregroundStyle(.secondary)
            }
            ForEach(entries.reversed()) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.message).font(.fig(.callout))
                    Text("\(e.date.formatted(date: .abbreviated, time: .standard)) · \(e.source.rawValue)/\(e.category)")
                        .font(.fig(.caption2)).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Log (\(entries.count))")
    }
}
