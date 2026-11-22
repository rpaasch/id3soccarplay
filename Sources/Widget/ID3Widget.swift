//
//  ID3Widget.swift
//  ID3Maps widget extension.
//
//  Battery widget for the home screen (small/medium) and the lock screen (circular, rectangular,
//  inline). Fetches the Worker status itself, falls back to the last state the app or the Maps
//  extension saved in the shared keychain. Refreshes every 30 min (10 min while charging); the
//  app also reloads it whenever the SoC or charging state changes.
//

import WidgetKit
import SwiftUI
import AppIntents

struct BatteryWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "ID.3 batteri"
    static let description = IntentDescription("Batteriprocent, rækkevidde og ladning.")
    init() {}
}

struct BatteryEntry: TimelineEntry {
    let date: Date
    let state: VehicleState?

    static let sample = BatteryEntry(
        date: .now,
        state: VehicleState(stateOfCharge: 0.62, measuredAt: .now, isCharging: false, rangeKm: 231)
    )
}

struct BatteryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry { .sample }

    func snapshot(for configuration: BatteryWidgetIntent, in context: Context) async -> BatteryEntry {
        if context.isPreview { return .sample }
        return BatteryEntry(date: .now, state: SharedStore.codable(.lastState))
    }

    func timeline(for configuration: BatteryWidgetIntent, in context: Context) async -> Timeline<BatteryEntry> {
        var state: VehicleState? = SharedStore.codable(.lastState)
        if let fresh = try? await StatusClient.fetch(timeout: 10, retryOnTimeout: true) {
            state = fresh
            SharedStore.setCodable(fresh, for: .lastState)
        }
        let minutes: Double = state?.isCharging == true ? 10 : 30
        return Timeline(entries: [BatteryEntry(date: .now, state: state)],
                        policy: .after(.now.addingTimeInterval(minutes * 60)))
    }
}

// MARK: Views

private func percent(_ s: VehicleState) -> Int { Int((s.stateOfCharge * 100).rounded()) }

private func socColor(_ s: VehicleState) -> Color {
    switch s.stateOfCharge {
    case ..<0.15: return .red
    case ..<0.30: return .orange
    default: return .green
    }
}

private func statusText(_ s: VehicleState) -> String {
    guard s.isCharging else { return "Parkeret" }
    var t = "Lader"
    if let k = s.chargeKind { t += " " + k.uppercased() }
    if let m = s.minutesToFull { t += " · \(m) min" }
    return t
}

/// "for 3 min. siden", updated by the system without reloading the widget.
private func ageText(_ s: VehicleState) -> Text {
    Text("for ") + Text(s.measuredAt, style: .relative) + Text(" siden")
}

private struct Ring: View {
    let state: VehicleState
    var lineWidth: CGFloat = 9
    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(socColor(state).opacity(0.2), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.01, min(1, state.stateOfCharge)))
                .stroke(socColor(state).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if state.isCharging { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow) }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(percent(state))").font(.system(.title, design: .rounded).bold()).monospacedDigit()
                    Text("%").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryEntry

    var body: some View {
        content.containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder private var content: some View {
        if let s = entry.state {
            switch family {
            case .accessoryCircular:
                Gauge(value: s.stateOfCharge) {
                    Image(systemName: s.isCharging ? "bolt.fill" : "car.fill")
                } currentValueLabel: {
                    Text("\(percent(s))")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("ID.3 \(percent(s)) %", systemImage: s.isCharging ? "bolt.fill" : "car.fill")
                        .font(.headline)
                    Text(s.rangeKm.map { "\(Int($0.rounded())) km · \(statusText(s))" } ?? statusText(s))
                        .font(.caption)
                    ageText(s).font(.caption2).foregroundStyle(.secondary)
                }
            case .accessoryInline:
                Text("ID.3 \(percent(s)) %" + (s.rangeKm.map { " · \(Int($0.rounded())) km" } ?? ""))
            case .systemMedium:
                HStack(spacing: 16) {
                    Ring(state: s).frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        if let r = s.rangeKm {
                            Text("\(Int(r.rounded())) km").font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                        }
                        Text(statusText(s)).font(.callout).foregroundStyle(s.isCharging ? .yellow : .secondary)
                        if let k = s.model?.consumptionKwhPer100 {
                            Text("Maps: \(k.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "da_DK")))) kWh/100 km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ageText(s).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(spacing: 6) {
                    Ring(state: s).frame(width: 84, height: 84)
                    if let r = s.rangeKm {
                        Text("\(Int(r.rounded())) km").font(.caption.bold()).monospacedDigit()
                    }
                    ageText(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "car.fill")
                Text("Åbn appen og indsæt tokenet").font(.caption2).multilineTextAlignment(.center)
            }
        }
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ID3Battery", intent: BatteryWidgetIntent.self, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("ID.3 batteri")
        .description("Batteriprocent, rækkevidde og ladning.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ID3WidgetBundle: WidgetBundle {
    var body: some Widget { BatteryWidget() }
}
