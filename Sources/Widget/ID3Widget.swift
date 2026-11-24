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
        let t0 = Date()
        do {
            let fresh = try await StatusClient.fetch(timeout: 10, retryOnTimeout: true)
            state = fresh
            online = true
            SharedStore.setCodable(fresh, for: .lastState)
            SharedLog.shared.log("widget refresh ok in \(Int(Date().timeIntervalSince(t0) * 1000)) ms", category: "widget")
        } catch {
            SharedLog.shared.log("widget refresh failed after \(Int(Date().timeIntervalSince(t0) * 1000)) ms: \((error as? URLError)?.code.rawValue ?? 0)", category: "widget")
        }
        // While driving, the OBD dongle's live value (seconds old) beats VW's (2-15 min old).
        var obd = false
        if let r: OBDReading = SharedStore.codable(.obdReading), r.isFreshAndValid,
           var s = state, r.at > s.measuredAt,
           abs(r.soc - s.stateOfCharge) <= 0.05 || Date().timeIntervalSince(s.measuredAt) >= 15 * 60 {
            s.stateOfCharge = r.soc
            s.measuredAt = r.at
            s.obdLive = true
            state = s
            obd = true
        }
        SharedLog.shared.flush()
        // Retry sooner when offline, charging or driving (the app also reloads on every percent).
        let minutes: Double = obd ? 5 : (!online ? 15 : (state?.isCharging == true ? 10 : 30))
        // Extra entries so the widget turns yellow/red by itself as the value ages (no refetch).
        let entries = [0.0, 6, 11, 16].map { m in
            BatteryEntry(date: .now.addingTimeInterval(m * 60), state: state, online: online)
        }
        return Timeline(entries: entries,
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

private enum Conn {
    case ok, aging, stale, offline, vwError
    init(_ e: BatteryEntry) {
        if let s = e.state {
            // Same rule as the app and Maps (Freshness), judged at this entry's time.
            switch Freshness.of(s, now: e.date).level {
            case .stale: self = e.online ? .stale : .offline; return
            case .aging: self = .aging; return
            case .fresh: break
            }
        }
        if !e.online { self = .offline }
        else if e.state?.workerError != nil { self = .vwError }
        else { self = .ok }
    }
    var color: Color {
        switch self { case .ok: .green; case .aging: .yellow; case .stale, .vwError: .red; case .offline: .orange }
    }
    var short: String {
        switch self {
        case .ok: "Friske tal"; case .aging: "Lidt gamle tal"; case .stale: "Gamle tal"
        case .offline: "Offline"; case .vwError: "VW svarer ikke"
        }
    }
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"; case .aging, .stale: "clock.badge.exclamationmark"
        case .offline: "wifi.slash"; case .vwError: "exclamationmark.triangle.fill"
        }
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

/// Big percentage with a slim bar underneath: reads at a glance and never crowds.
private struct SocBlock: View {
    let state: VehicleState
    var size: CGFloat = 46
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(percent(state))").font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
                Text("%").font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if state.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.yellow)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Bar(value: state.stateOfCharge, color: socColor(state))
        }
    }
}

private struct Bar: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                Capsule().fill(color.gradient).frame(width: max(6, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

/// Main line under the number: charging power and type, else the range.
private func primaryLine(_ s: VehicleState) -> String {
    if s.isCharging {
        var parts: [String] = []
        if let w = s.chargePowerW { parts.append("\(num(w / 1000, w < 20000 ? 1 : 0)) kW") }
        if let k = s.chargeKind { parts.append(k.uppercased()) }
        return parts.isEmpty ? "Lader" : parts.joined(separator: " · ")
    }
    return s.rangeKm.map { "\(Int($0.rounded())) km" } ?? "–"
}

/// Second line: when the car is full (while charging), else when it was measured.
private func secondaryLine(_ s: VehicleState) -> Text {
    if s.isCharging, let m = s.minutesToFull {
        let full = Date().addingTimeInterval(Double(m) * 60)
        return Text("fuld kl. " + full.formatted(.dateTime.hour().minute().locale(dk)))
    }
    return Text("målt ") + ageText(s.measuredAt)
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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        header(link)
                        Spacer(minLength: 4)
                        SocBlock(state: s)
                        Spacer(minLength: 8)
                        Text(primaryLine(s))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
                            .foregroundStyle(s.isCharging ? .yellow : .primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        secondaryLine(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Maps regner med").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        if let m = s.model {
                            mediumRow("by", binValue(m, 2))
                            mediumRow("landevej", binValue(m, 4))
                            mediumRow("motorvej", binValue(m, 6))
                            if let t = m.temperatureC {
                                Text("\(num(t, 0)) °C · \(m.batteryWarm == true ? "varmt" : "koldt") batteri")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .systemLarge:
                large(s, link)
            default:
                // Small (also the CarPlay widget): one glance, left-aligned, nothing that ticks.
                VStack(alignment: .leading, spacing: 0) {
                    header(link)
                    Spacer(minLength: 4)
                    SocBlock(state: s)
                    Spacer(minLength: 8)
                    Text(primaryLine(s))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(s.isCharging ? .yellow : .primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    secondaryLine(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "car.fill")
                Text("Åbn appen og indsæt tokenet").font(.caption2).multilineTextAlignment(.center)
            }
        }
    }

    /// "ID.3" and a small connection dot (green / orange / red).
    private func header(_ link: Conn) -> some View {
        HStack(spacing: 5) {
            Text("ID.3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            // Spelled out whenever the numbers can't be trusted (also in CarPlay).
            if link != .ok {
                Text(link.short).font(.caption2.weight(.semibold)).foregroundStyle(link.color).lineLimit(1)
            }
            Circle().fill(link.color).frame(width: 7, height: 7)
        }
    }

    private func mediumRow(_ label: String, _ value: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value.map { num($0, 0) } ?? "–").font(.system(.callout, design: .rounded).bold()).monospacedDigit()
            Text("kWh").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Everything the Worker knows, on one widget.
    private func large(_ s: VehicleState, _ link: Conn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                SocBlock(state: s, size: 52).frame(width: 150)
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
                case .ok, .aging, .stale: (Text("bil målt ") + ageText(s.measuredAt)).font(.caption2).foregroundStyle(.secondary)
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
