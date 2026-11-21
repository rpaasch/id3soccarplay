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
            Circle().stroke(color.opacity(0.18), lineWidth: 16)
            Circle()
                .trim(from: 0, to: max(0.01, min(1, soc)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: soc)
            VStack(spacing: 0) {
                if charging {
                    Image(systemName: "bolt.fill").font(.title3).foregroundStyle(.yellow)
                }
                Text("\(Int((soc * 100).rounded()))")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%").font(.headline).foregroundStyle(.secondary)
            }
        }
        .frame(width: 170, height: 170)
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

    private var bars: [Bar] {
        let mids = [10.0, 30, 50, 70, 90, 110, 130, 150]
        return mids.enumerated().map { i, v in
            Bar(id: i, label: "\(Int(v))", kwh: bins[i] + auxW / 1000 / v * 100)
        }
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(x: .value("km/t", b.label), y: .value("kWh/100 km", b.kwh))
                .foregroundStyle(.teal.gradient)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(Int(b.kwh.rounded()))").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartYAxis(.hidden)
        .chartXAxisLabel("km/t")
        .frame(height: 140)
        .accessibilityLabel("Forbrug efter fart, som Maps regner med")
    }
}

/// One trip with actual vs predicted consumption.
struct TripCard: View {
    let trip: Trip

    private var verdict: (String, Color) {
        switch trip.ratio {
        case ..<0.95: return ("brugte mindre", .green)
        case ..<1.08: return ("som forudsagt", .green)
        case ..<1.25: return ("lidt mere", .orange)
        default: return ("mere end forudsagt", .red)
        }
    }

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.startDate.formatted(.dateTime.weekday(.wide).hour().minute()))
                        .font(.headline)
                    Text([
                        String(format: "%.0f km", trip.km),
                        String(format: "%.0f → %.0f %%", trip.socFrom * 100, trip.socTo * 100),
                        trip.tempC.map { String(format: "%.0f °C", $0) },
                        trip.cold == true ? "koldstart" : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(text: String(format: "×%.2f", trip.ratio), symbol: "gauge.with.dots.needle.50percent", tint: verdict.1)
            }
            VStack(spacing: 6) {
                bar(label: "Faktisk", value: trip.kwhPer100, max: maxValue, color: .primary)
                bar(label: "Forudsagt", value: trip.predictedPer100, max: maxValue, color: .teal)
            }
            Text(verdict.0).font(.caption).foregroundStyle(verdict.1)
        }
        .accessibilityElement(children: .combine)
    }

    private var maxValue: Double { max(trip.kwhPer100, trip.predictedPer100, 1) }

    private func bar(label: String, value: Double, max: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            GeometryReader { g in
                Capsule().fill(color.opacity(0.85))
                    .frame(width: g.size.width * value / max)
            }
            .frame(height: 8)
            Text(String(format: "%.1f", value)).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
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
