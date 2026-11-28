//
//  ChartViews.swift
//  ID3Maps host app.
//
//  Charts built from data the app already has: the trips (used vs. what Maps was told, with
//  temperature and speed) and the battery output from the dongle's energy counter.
//

import SwiftUI
import Charts

/// Battery output over the current drive, from the dongle's energy counter.
struct PowerChart: View {
    let points: [PowerPoint]

    var body: some View {
        let avg = points.map(\.kw).reduce(0, +) / Double(max(1, points.count))
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Tid", p.at), y: .value("kW", p.kw))
                        .foregroundStyle(.teal.opacity(0.15).gradient)
                    LineMark(x: .value("Tid", p.at), y: .value("kW", p.kw))
                        .foregroundStyle(.teal)
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Gennemsnit", avg))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYAxisLabel("kW")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .frame(height: 150)
            Text("Gennemsnit \(DK.num(avg, 1)) kW, senest \(DK.num(points.last?.kw ?? 0, 1)) kW. Målt med batteriets egen energitæller hvert 15. sekund. Skalaen læres af, hvor meget batteriprocenten falder, så den passer bedre efter hver tur.")
                .font(.fig(.caption2)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Batteriets effekt under turen, gennemsnit \(DK.num(avg, 1)) kilowatt")
    }
}

/// Four explorable charts over all trips: touch or drag on a chart to see that trip's details,
/// tap the expand button for a full-screen chart you can pinch to zoom, with an AI analysis.
/// Two columns on wide screens (the foldable's inner display).
struct TripCharts: View {
    let trips: [Trip]

    private var counted: [Trip] { trips.filter(\.isCounted).sorted { $0.start < $1.start } }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
            if counted.count >= 2 {
                AccuracyChart(trips: Array(counted.suffix(60)))
                OverTimeChart(trips: counted)
            }
            if counted.contains(where: { $0.tempC != nil }) {
                ScatterChart(trips: counted.filter { $0.tempC != nil }, kind: .temperature)
            }
            if counted.contains(where: { $0.avgKmh != nil }) {
                ScatterChart(trips: counted.filter { $0.avgKmh != nil }, kind: .speed)
            }
        }
    }
}

/// How far a trip's real consumption was from Maps' (+ = used more).
private func deviation(_ t: Trip) -> Double { (t.vsMaps - 1) * 100 }

private func hitColor(_ t: Trip) -> Color {
    let p = deviation(t)
    return abs(p) <= 5 ? .green : (p > 0 ? .orange : .blue)
}

private let gridLine = StrokeStyle(lineWidth: 0.5)

/// The trips as compact text lines for the AI analysis (no positions, only per-trip aggregates).
func tripsDigest(_ trips: [Trip]) -> String {
    let lines = trips.suffix(40).map { t -> String in
        var parts = [t.startDate.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(DK.locale)),
                     "\(DK.num(t.km, 0)) km",
                     "brugte \(DK.num(t.kwhPer100, 1))",
                     "Maps \(DK.num(t.mapsValue, 1)) kWh/100 km",
                     "afvigelse \(Int(deviation(t).rounded())) %"]
        if let c = t.tempC { parts.append("\(DK.num(c, 0)) °C") }
        if let v = t.avgKmh { parts.append("\(DK.num(v, 0)) km/t") }
        return parts.joined(separator: "; ")
    }
    return lines.joined(separator: "\n")
}

/// A chart card with an expand button; the expanded version is shown full screen.
private struct ChartFrame<Content: View>: View {
    let title: String
    let symbol: String
    let expanded: Bool
    let analysisQuestion: String
    let analysisData: String
    var full: () -> AnyView
    @ViewBuilder var content: Content
    @State private var showFull = false

    var body: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 12) { content }
        } else {
            Card(title: title, symbol: symbol) { content }
                .overlay(alignment: .topTrailing) {
                    Button { showFull = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.fig(.subheadline, .semibold))
                            .padding(10)
                            .background(Color(.tertiarySystemFill), in: Circle())
                    }
                    .padding(10)
                    .accessibilityLabel("Forstør \(title)")
                }
                .fullScreenCover(isPresented: $showFull) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                full()
                                AnalysisPanel(question: analysisQuestion, data: analysisData)
                            }
                            .padding(20)
                            .frame(maxWidth: 1100)
                            .frame(maxWidth: .infinity)
                        }
                        .background(Color(.systemGroupedBackground))
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Luk") { showFull = false } }
                        }
                    }
                }
        }
    }
}

/// Two-finger pinch changes how much of the x axis is visible.
private struct PinchZoom: ViewModifier {
    @Binding var length: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            MagnifyGesture()
                .onChanged { v in
                    let s = start ?? length
                    if start == nil { start = length }
                    length = min(range.upperBound, max(range.lowerBound, s / v.magnification))
                }
                .onEnded { _ in start = nil }
        )
    }
}

/// The details of one trip, shown under a chart while it is touched.
private struct TripBubble: View {
    let trip: Trip
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trip.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(DK.locale)))
                .font(.fig(.caption, .semibold))
            Text("\(DK.num(trip.km, 0)) km · brugte \(DK.num(trip.kwhPer100, 1)) · Maps \(DK.num(trip.mapsValue, 1)) kWh/100 km")
                .font(.fig(.caption2)).monospacedDigit()
            HStack(spacing: 8) {
                Text((deviation(trip) >= 0 ? "+" : "") + "\(Int(deviation(trip).rounded())) %").foregroundStyle(hitColor(trip)).bold()
                if let c = trip.tempC { Text("\(DK.num(c, 0)) °C") }
                if let v = trip.avgKmh { Text("\(DK.num(v, 0)) km/t") }
            }
            .font(.fig(.caption2)).monospacedDigit()
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SelectionLine: View {
    let trip: Trip?
    let hint: String
    var body: some View {
        Group {
            if let t = trip { TripBubble(trip: t) } else {
                Label(hint, systemImage: "hand.tap").font(.fig(.caption2)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    }
}

// MARK: Accuracy

private struct AccuracyChart: View {
    let trips: [Trip]
    var expanded = false
    @State private var selected: String?
    @State private var visibleBars = 30.0

    private var selectedTrip: Trip? { selected.flatMap(Int.init).flatMap { trips.indices.contains($0) ? trips[$0] : nil } }

    var body: some View {
        let within = trips.filter { abs(deviation($0)) <= 5 }.count
        let span = max(15, (trips.map { abs(deviation($0)) }.max() ?? 15) + 5)
        ChartFrame(title: "Ramte Maps forbruget?", symbol: "target", expanded: expanded,
                   analysisQuestion: "Hvor godt rammer Maps' forbrug de rigtige ture? Er der et mønster i, hvornår Maps tager fejl (temperatur, fart, turens længde, over tid)? Bliver det bedre?",
                   analysisData: tripsDigest(trips), full: { AnyView(AccuracyChart(trips: trips, expanded: true)) }) {
            Chart {
                ForEach([-5.0, 5.0], id: \.self) { y in
                    RuleMark(y: .value("Grænse", y))
                        .foregroundStyle(Color.green.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(trips.enumerated()), id: \.element.id) { i, t in
                    BarMark(x: .value("Tur", String(i)), y: .value("Afvigelse", deviation(t)))
                        .foregroundStyle(hitColor(t).opacity(selected == nil || selected == String(i) ? 1 : 0.35))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Nul", 0)).foregroundStyle(Color.secondary.opacity(0.6))
            }
            .chartXSelection(value: $selected)
            .chartYScale(domain: -span...span)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                    AxisGridLine(stroke: gridLine).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(x > 0 ? "+" : "")\(Int(x)) %") } }
                }
            }
            .chartScrollableAxes(expanded ? .horizontal : [])
            .chartXVisibleDomain(length: expanded ? Int(visibleBars) : trips.count)
            .chartScrollPosition(initialX: String(max(0, trips.count - Int(visibleBars))))
            .modifier(PinchZoom(length: $visibleBars, range: 5...Double(max(6, trips.count))))
            .frame(height: expanded ? 420 : 170)
            SelectionLine(trip: selectedTrip, hint: expanded ? "Knib for at zoome, rul til siden, træk for at se hver tur" : "Træk hen over søjlerne for at se hver tur")
            Text("Ældste tur til venstre. Over nul brugte bilen mere, end Maps regnede med. \(within) af \(trips.count) ture ramte inden for ±5 % (mellem de grønne streger).")
                .font(.fig(.caption2)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Over time

private struct OverTimeChart: View {
    let trips: [Trip]
    var expanded = false
    @State private var selectedDate: Date?
    @State private var visibleDays = 14.0

    private var selectedTrip: Trip? {
        guard let d = selectedDate else { return nil }
        return trips.min { abs($0.startDate.timeIntervalSince(d)) < abs($1.startDate.timeIntervalSince(d)) }
    }

    var body: some View {
        let top = (trips.flatMap { [$0.kwhPer100, $0.mapsValue] }.max() ?? 30) * 1.15
        let spanDays = max(2, ((trips.last?.start ?? 0) - (trips.first?.start ?? 0)) / 86_400_000 + 1)
        ChartFrame(title: "Forbrug over tid", symbol: "chart.line.uptrend.xyaxis", expanded: expanded,
                   analysisQuestion: "Hvordan har forbruget udviklet sig over tid, og hvor godt har Maps fulgt med? Er der dage eller ture, der skiller sig ud, og hvad kan forklare det?",
                   analysisData: tripsDigest(trips), full: { AnyView(OverTimeChart(trips: trips, expanded: true)) }) {
            Chart {
                ForEach(trips) { t in
                    LineMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.mapsValue), series: .value("Hvad", "Maps"))
                        .foregroundStyle(by: .value("Hvad", "Maps"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.kwhPer100), series: .value("Hvad", "Brugte"))
                        .foregroundStyle(by: .value("Hvad", "Brugte"))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.kwhPer100))
                        .foregroundStyle(hitColor(t))
                        .symbolSize(selectedTrip?.id == t.id ? 120 : (expanded ? 45 : 30))
                }
                if let t = selectedTrip {
                    RuleMark(x: .value("Valgt", t.startDate)).foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .chartForegroundStyleScale(["Brugte": Color.primary, "Maps": Color.teal])
            .chartLegend(position: .top, alignment: .leading)
            .chartYScale(domain: 0...top)
            .chartXSelection(value: $selectedDate)
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: min(visibleDays, spanDays) * 86_400)
            .chartScrollPosition(initialX: (trips.last?.startDate ?? .now).addingTimeInterval(-(min(visibleDays, spanDays) - 1) * 86_400))
            .modifier(PinchZoom(length: $visibleDays, range: 1...max(2, spanDays)))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: expanded ? 8 : 4)) { _ in
                    AxisGridLine(stroke: gridLine).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(DK.locale))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: gridLine).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .frame(height: expanded ? 420 : 190)
            SelectionLine(trip: selectedTrip, hint: "Knib for at zoome, rul til siden for ældre ture, tryk for detaljer")
            Text("kWh pr. 100 km. Jo tættere de to linjer ligger, jo bedre passer Maps' rækkevidde og ankomstprocent.")
                .font(.fig(.caption2)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Scatter (temperature / speed)

enum ScatterKind: Sendable {
    case temperature, speed

    var title: String { self == .temperature ? "Forbrug og temperatur" : "Forbrug og fart" }
    var symbol: String { self == .temperature ? "thermometer.medium" : "speedometer" }
    var xLabel: String { self == .temperature ? "udetemperatur, °C" : "gennemsnitsfart, km/t" }
    func x(_ t: Trip) -> Double { self == .temperature ? (t.tempC ?? 0) : (t.avgKmh ?? 0) }
    var note: String {
        self == .temperature
            ? "Hver prik er en tur. Farven viser, om Maps ramte. Kulde giver mere varme og et koldere batteri."
            : "Langsomme ture bruger mere pr. km om vinteren, fordi varmen kører, uanset hvor langt bilen kommer."
    }
    var question: String {
        self == .temperature
            ? "Hvordan afhænger forbruget af udetemperaturen? Hvor meget stiger det pr. grad koldere, og rammer Maps bedre ved nogle temperaturer end andre?"
            : "Hvordan afhænger forbruget af gennemsnitsfarten? Hvilken fart er mest økonomisk, og hvor tager Maps mest fejl?"
    }
}

private struct ScatterChart: View {
    let trips: [Trip]
    let kind: ScatterKind
    var expanded = false
    @State private var selectedX: Double?
    @State private var visibleWidth: Double?

    private var selectedTrip: Trip? {
        guard let v = selectedX else { return nil }
        return trips.min { abs(kind.x($0) - v) < abs(kind.x($1) - v) }
    }

    var body: some View {
        let xs = trips.map(kind.x)
        let lo = (xs.min() ?? 0), hi = (xs.max() ?? 1)
        let pad = max(1, (hi - lo) * 0.08)
        let full = (hi - lo) + 2 * pad
        let top = (trips.map(\.kwhPer100).max() ?? 30) * 1.15
        ChartFrame(title: kind.title, symbol: kind.symbol, expanded: expanded,
                   analysisQuestion: kind.question, analysisData: tripsDigest(trips),
                   full: { AnyView(ScatterChart(trips: trips, kind: kind, expanded: true)) }) {
            Chart {
                ForEach(trips) { t in
                    PointMark(x: .value(kind.xLabel, kind.x(t)), y: .value("kWh/100 km", t.kwhPer100))
                        .foregroundStyle(hitColor(t).opacity(selectedTrip == nil || selectedTrip?.id == t.id ? 0.9 : 0.3))
                        .symbolSize(selectedTrip?.id == t.id ? 160 : (expanded ? 80 : 55))
                }
                if let t = selectedTrip {
                    RuleMark(x: .value("Valgt", kind.x(t))).foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .chartXSelection(value: $selectedX)
            .chartXScale(domain: (lo - pad)...(hi + pad))
            .chartYScale(domain: 0...top)
            .chartScrollableAxes(expanded ? .horizontal : [])
            .chartXVisibleDomain(length: expanded ? (visibleWidth ?? full) : full)
            .modifier(PinchZoom(length: Binding(get: { visibleWidth ?? full }, set: { visibleWidth = $0 }),
                                range: max(1, full / 10)...full))
            .chartXAxisLabel(kind.xLabel, alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: gridLine).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: expanded ? 8 : 5)) { _ in
                    AxisGridLine(stroke: gridLine).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .frame(height: expanded ? 420 : 170)
            HStack(spacing: 12) {
                ForEach([("Maps ramte", Color.green), ("brugte mere", Color.orange), ("brugte mindre", Color.blue)], id: \.0) { l in
                    HStack(spacing: 4) { Circle().fill(l.1).frame(width: 8, height: 8); Text(l.0) }
                }
            }
            .font(.fig(.caption2)).foregroundStyle(.secondary)
            SelectionLine(trip: selectedTrip, hint: expanded ? "Knib for at zoome, træk for at se hver tur" : "Træk hen over grafen for at se hver tur")
            Text(kind.note).font(.fig(.caption2)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
