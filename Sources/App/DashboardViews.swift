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

/// The big state-of-charge ring.
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
        ZStack {
            // Inset by half the line width so the stroke stays inside the frame.
            Circle().inset(by: 6.5).stroke(color.opacity(0.18), lineWidth: 13)
            Circle().inset(by: 6.5)
                .trim(from: 0, to: max(0.01, min(1, soc)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: soc)
            VStack(spacing: 0) {
                if charging {
                    Image(systemName: "bolt.fill").font(.callout).foregroundStyle(.yellow)
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((soc * 100).rounded()))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.headline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 128, height: 128)
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

    private struct Bar: Identifiable { let id: Int; let label: String; let kwh: Double }

    static let mids = [10.0, 30, 50, 70, 90, 110, 130, 150]

    /// kWh/100 km at speed bin `i` including heating (aux power spread over the km driven).
    static func value(bins: [Double], auxW: Double, index i: Int) -> Double {
        bins[i] + auxW / 1000 / mids[i] * 100
    }

    private var bars: [Bar] {
        Self.mids.indices.map { i in
            Bar(id: i, label: "\(Int(Self.mids[i]))", kwh: Self.value(bins: bins, auxW: auxW, index: i))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("kWh pr. 100 km ved hver fart").font(.caption2).foregroundStyle(.secondary)
            Chart(bars) { b in
                BarMark(x: .value("km/t", b.label), y: .value("kWh/100 km", b.kwh), width: .ratio(0.6))
                    .foregroundStyle(.teal.gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        Text("\(Int(b.kwh.rounded()))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks { _ in AxisValueLabel().font(.caption2) }
            }
            .frame(height: 110)
            Text("km/t").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Forbrug efter fart, som Maps regner med")
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
        switch trip.ratio {
        case ..<0.95: return .blue
        case ..<1.08: return .green
        case ..<1.25: return .orange
        default: return .red
        }
    }

    private var verdict: String {
        guard trip.isCounted else { return "For kort til at tælle med – batteriet melder kun hele procent." }
        let pct = Int(((trip.ratio - 1) * 100).rounded())
        switch trip.ratio {
        case ..<0.95: return "Brugte \(-pct) % mindre end forudsagt"
        case ..<1.08: return "Som forudsagt"
        default: return "Brugte \(pct) % mere end forudsagt"
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
                Text("×" + DK.num(trip.ratio, 2))
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
                bar("Maps", trip.predictedPer100, .teal)
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
