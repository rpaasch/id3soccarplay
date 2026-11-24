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
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .font(.callout)
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
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.yellow)
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

/// Small capsule showing a status.
struct StatusChip: View {
    let text: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Maps' consumption per speed bin (kWh/100 km incl. heating) as small bars.
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

    private var parts: [Part] {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("kWh pr. 100 km ved hver fart").font(.caption2).foregroundStyle(.secondary)
            Chart(parts) { p in
                BarMark(x: .value("km/t", p.label), y: .value("kWh/100 km", p.kwh), width: .ratio(0.6))
                    .foregroundStyle(by: .value("Del", p.kind))
                    .annotation(position: .top, spacing: 2) {
                        if p.top {
                            Text("\(Int(p.total.rounded()))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
            }
            .chartForegroundStyleScale([Self.drivingLabel: Color.teal, Self.heatingLabel: Color.orange,
                                        Self.coldLabel: Color.orange.opacity(0.45)])
            .chartLegend(position: .top, alignment: .leading, spacing: 6)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 130)
            Text("km/t").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            Text(note)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Forbrug efter fart, som Maps regner med, delt i kørsel og varme")
    }

    private var note: String {
        let steady = (auxW - coldW) / 1000
        var s = "Varmen bruger ca. \(DK.num(steady, 1)) kW, uanset fart. Kører du langsomt, tager hver km længere tid, så varmens andel pr. km bliver stor. Pr. time bruger bilen ved 10 km/t kun ca. \(DK.num(bins[0] / 10 + auxW / 1000, 1)) kW mod \(DK.num(auxW / 1000, 1)) kW, når den holder stille."
        if coldW > 0 {
            s += " Bilen er kold lige nu, så Maps får \(DK.num(coldW / 1000, 1)) kW ekstra, til den er varmet op (ca. de første 15 min)."
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
                ? "For kort til at tælle med – batteriet melder kun hele procent."
                : "Tæller ikke med – forbruget ligger så langt fra det forventede, at målingen nok er forkert."
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
                        .font(.headline).monospacedDigit()
                    Text("\(trip.minutes) min" + ((trip.joined ?? 1) > 1 ? " · med kort stop" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text((trip.vsMaps >= 1 ? "+" : "−") + DK.num(abs(trip.vsMaps - 1) * 100, 0) + " %")
                    .font(.subheadline.weight(.bold)).monospacedDigit()
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
            .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 6) {
                bar("Brugte", trip.kwhPer100, trip.isCounted ? .primary : .secondary)
                bar("Maps", trip.mapsValue, .teal)
            }
            .padding(.top, 2)

            HStack(spacing: 6) {
                if trip.cold == true { Image(systemName: "snowflake").foregroundStyle(.cyan) }
                Text(verdict).foregroundStyle(trip.isCounted ? tint : .secondary)
            }
            .font(.caption)
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
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color.opacity(0.85))
                        .frame(width: max(6, g.size.width * min(1, value / max(scale, 1))))
                }
            }
            .frame(height: 8)
            Text(DK.num(value)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
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
                    Text(e.message).font(.callout)
                    Text("\(e.date.formatted(date: .abbreviated, time: .standard)) · \(e.source.rawValue)/\(e.category)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Log (\(entries.count))")
    }
}
