//
//  ID3Widget.swift
//  ID3Maps widget extension.
//
//  Battery widget for the home screen (small, medium, large) and the lock screen (circular,
//  rectangular, inline). Fetches the Worker status itself and falls back to the last state the
//  app or the Maps extension saved in the shared keychain. Shows whether the connection works:
//  green = fresh from the Worker, orange = no connection (last known values), red = the Worker
//  cannot reach VW. Refreshes every 30 min (10 min while charging); the app also reloads it
//  whenever the SoC or charging state changes.
//

import WidgetKit
import SwiftUI
import AppIntents

struct BatteryWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "ID.3 batteri"
    static let description = IntentDescription("Batteri, rækkevidde, ladning, forbrug og forbindelse.")
    init() {}
}

struct BatteryEntry: TimelineEntry {
    let date: Date
    let state: VehicleState?
    /// True when this entry was fetched from the Worker just now (false = last known values).
    let online: Bool

    static let sample = BatteryEntry(
        date: .now,
        state: VehicleState(stateOfCharge: 0.62, measuredAt: .now, isCharging: false, rangeKm: 231),
        online: true
    )
}

struct BatteryProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry { .sample }

    func snapshot(for configuration: BatteryWidgetIntent, in context: Context) async -> BatteryEntry {
        if context.isPreview { return .sample }
        return BatteryEntry(date: .now, state: SharedStore.codable(.lastState), online: false)
    }

    func timeline(for configuration: BatteryWidgetIntent, in context: Context) async -> Timeline<BatteryEntry> {
        var state: VehicleState? = SharedStore.codable(.lastState)
        var online = false
        if let fresh = try? await StatusClient.fetch(timeout: 10, retryOnTimeout: true) {
            state = fresh
            online = true
            SharedStore.setCodable(fresh, for: .lastState)
        }
        // Retry sooner when offline or charging.
        let minutes: Double = !online ? 15 : (state?.isCharging == true ? 10 : 30)
        return Timeline(entries: [BatteryEntry(date: .now, state: state, online: online)],
                        policy: .after(.now.addingTimeInterval(minutes * 60)))
    }
}

// MARK: Helpers

private let dk = Locale(identifier: "da_DK")
private func num(_ v: Double, _ d: Int = 1) -> String { v.formatted(.number.precision(.fractionLength(d)).locale(dk)) }
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
    if let w = s.chargePowerW { t += " · \(num(w / 1000, w < 20000 ? 1 : 0)) kW" }
    if let m = s.minutesToFull { t += " · \(duration(m))" }
    return t
}

/// kWh/100 km Maps uses at speed bin `i` (bins are 20 km/h wide), heating included.
private func binValue(_ m: ModelHints, _ i: Int) -> Double? {
    guard let bins = m.consumptionBinsKwhPer100, bins.count == 10 else { return nil }
    let mids = [10.0, 30, 50, 70, 90, 110, 130, 150, 170, 190]
    return bins[i] + (m.auxPowerW ?? 500) / 1000 / mids[i] * 100
}

/// "kl. 20.58" (today) or "21/11 20.58": short and still, no ticking seconds.
private func ageText(_ d: Date) -> Text {
    let time = d.formatted(.dateTime.hour().minute().locale(dk))
    if Calendar.current.isDateInToday(d) { return Text("kl. \(time)") }
    return Text(d.formatted(.dateTime.day().month(.defaultDigits).locale(dk)) + " " + time)
}

/// "25 min" or "4 t 55 min".
private func duration(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes) min" : "\(minutes / 60) t \(minutes % 60) min"
}

/// One short line under the ring: charging details, else range.
private func smallLine(_ s: VehicleState) -> String {
    if s.isCharging {
        var parts: [String] = []
        if let w = s.chargePowerW { parts.append("\(num(w / 1000, w < 20000 ? 1 : 0)) kW") }
        if let m = s.minutesToFull { parts.append(duration(m)) }
        return parts.isEmpty ? "Lader" : parts.joined(separator: " · ")
    }
    return s.rangeKm.map { "\(Int($0.rounded())) km" } ?? ""
}

private enum Conn {
    case ok, offline, vwError
    init(_ e: BatteryEntry) {
        if !e.online { self = .offline }
        else if e.state?.workerError != nil { self = .vwError }
        else { self = .ok }
    }
    var color: Color { switch self { case .ok: .green; case .offline: .orange; case .vwError: .red } }
    var short: String { switch self { case .ok: "Forbundet"; case .offline: "Offline"; case .vwError: "VW svarer ikke" } }
    var symbol: String {
        switch self { case .ok: "checkmark.circle.fill"; case .offline: "wifi.slash"; case .vwError: "exclamationmark.triangle.fill" }
    }
}

private struct LinkBadge: View {
    let link: Conn
    var showText = true
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: link.symbol)
            if showText { Text(link.short) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(link.color)
    }
}

private struct Ring: View {
    let state: VehicleState
    var lineWidth: CGFloat = 9
    var numberSize: CGFloat = 30
    var body: some View {
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(socColor(state).opacity(0.2), lineWidth: lineWidth)
            Circle().inset(by: lineWidth / 2)
                .trim(from: 0, to: max(0.01, min(1, state.stateOfCharge)))
                .stroke(socColor(state).gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // The number alone, exactly centred; "%" small underneath (nothing beside it to push it off centre).
            VStack(spacing: -2) {
                Text("\(percent(state))")
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("%")
                    .font(.system(size: numberSize * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, lineWidth + 6)
        }
    }
}

private struct Row: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(tint)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.caption)
    }
}

// MARK: Views

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryEntry

    var body: some View {
        content.containerBackground(for: .widget) { Color(.systemBackground) }
    }

    @ViewBuilder private var content: some View {
        if let s = entry.state {
            let link = Conn(entry)
            switch family {
            case .accessoryCircular:
                Gauge(value: s.stateOfCharge) {
                    Image(systemName: link == .ok ? (s.isCharging ? "bolt.fill" : "car.fill") : link.symbol)
                } currentValueLabel: {
                    Text("\(percent(s))")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Label("ID.3 \(percent(s)) %", systemImage: s.isCharging ? "bolt.fill" : "car.fill").font(.headline)
                        if link != .ok { Image(systemName: link.symbol) }
                    }
                    Text(s.rangeKm.map { "\(Int($0.rounded())) km · \(statusText(s))" } ?? statusText(s)).font(.caption)
                    ageText(s.measuredAt).font(.caption2).foregroundStyle(.secondary)
                }
            case .accessoryInline:
                Text("ID.3 \(percent(s)) %" + (s.rangeKm.map { " · \(Int($0.rounded())) km" } ?? "") + (link == .ok ? "" : " · \(link.short)"))
            case .systemMedium:
                HStack(spacing: 14) {
                    Ring(state: s).frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            if let r = s.rangeKm {
                                Text("\(Int(r.rounded())) km").font(.system(.title3, design: .rounded).bold()).monospacedDigit()
                            }
                            Spacer(minLength: 4)
                            LinkBadge(link: link)
                        }
                        Text(statusText(s)).font(.caption).foregroundStyle(s.isCharging ? .yellow : .secondary)
                        if let m = s.model, let city = binValue(m, 2), let mw = binValue(m, 6) {
                            Text("Maps: by \(num(city, 0)) · motorvej \(num(mw, 0)) kWh").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let t = s.model?.temperatureC {
                            Text("\(num(t, 0)) °C · \(s.model?.batteryWarm == true ? "varmt" : "koldt") batteri").font(.caption2).foregroundStyle(.secondary)
                        }
                        ageText(s.measuredAt).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            case .systemLarge:
                large(s, link)
            default:
                // Small (also the CarPlay widget): one glance, nothing that ticks.
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Text("ID.3").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        ageText(s.measuredAt).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: link.symbol).font(.caption2).foregroundStyle(link.color)
                    }
                    Ring(state: s, lineWidth: 10, numberSize: 32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack(spacing: 3) {
                        if s.isCharging { Image(systemName: "bolt.fill") }
                        Text(smallLine(s))
                    }
                    .font(.system(.subheadline, design: .rounded).bold()).monospacedDigit()
                    .foregroundStyle(s.isCharging ? .yellow : .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "car.fill")
                Text("Åbn appen og indsæt tokenet").font(.caption2).multilineTextAlignment(.center)
            }
        }
    }

    /// Everything the Worker knows, on one widget.
    private func large(_ s: VehicleState, _ link: Conn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Ring(state: s, lineWidth: 11, numberSize: 36).frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 3) {
                    if let r = s.rangeKm {
                        Text("\(Int(r.rounded())) km").font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                        Text("rækkevidde ifølge bilen").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(statusText(s)).font(.callout.weight(.semibold)).foregroundStyle(s.isCharging ? .yellow : .primary)
                    if s.socEstimated == true {
                        Text("procent fremskrevet under kørsel").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let m = s.model {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maps regner med (kWh/100 km)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        speedTile("by 50", binValue(m, 2))
                        speedTile("landevej 90", binValue(m, 4))
                        speedTile("motorvej 130", binValue(m, 6))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let c = m.tripCalibration {
                        Row(symbol: "dial.medium", text: "Kalibrering ×\(num(c.factor, 2)) · \(c.n) ture, \(num(c.km, 0)) km")
                    }
                    if let t = m.temperatureC {
                        Row(symbol: m.batteryWarm == true ? "thermometer.sun.fill" : "snowflake",
                            text: "\(num(t, 0)) °C ude · \(m.batteryWarm == true ? "varmt" : "koldt") batteri",
                            tint: m.batteryWarm == true ? .orange : .cyan)
                    }
                    if let a = m.auxPowerW {
                        Row(symbol: "heater.vertical", text: "Varme m.m. \(num(a / 1000)) kW")
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                LinkBadge(link: link)
                Spacer(minLength: 4)
                switch link {
                case .ok: (Text("bil målt ") + ageText(s.measuredAt)).font(.caption2).foregroundStyle(.secondary)
                case .offline: (Text("sidst kendte, hentet ") + ageText(s.contactAt ?? s.measuredAt)).font(.caption2).foregroundStyle(.secondary)
                case .vwError: Text("viser sidste måling").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func speedTile(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.map { num($0, 0) } ?? "–").font(.system(.title3, design: .rounded).bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ID3Battery", intent: BatteryWidgetIntent.self, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("ID.3 batteri")
        .description("Batteri, rækkevidde, ladning, forbrug og forbindelse.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ID3WidgetBundle: WidgetBundle {
    var body: some Widget { BatteryWidget() }
}
