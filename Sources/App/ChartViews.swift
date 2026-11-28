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
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Batteriets effekt under turen, gennemsnit \(DK.num(avg, 1)) kilowatt")
    }
}

/// Four explorable charts over all trips: touch or drag on a chart to see that trip's details.
/// Two columns on wide screens (the foldable's inner display).
struct TripCharts: View {
    let trips: [Trip]

    private var counted: [Trip] { trips.filter(\.isCounted).sorted { $0.start < $1.start } }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)], spacing: 14) {
            if counted.count >= 2 {
                AccuracyChart(trips: Array(counted.suffix(40)))
                OverTimeChart(trips: counted)
            }
            if counted.contains(where: { $0.tempC != nil }) {
                ScatterChart(trips: counted.filter { $0.tempC != nil }, title: "Forbrug og temperatur", symbol: "thermometer.medium",
                             xLabel: "udetemperatur, °C", x: { $0.tempC ?? 0 },
                             note: "Hver prik er en tur. Tryk eller træk for at se turen. Farven viser, om Maps ramte.")
            }
            if counted.contains(where: { $0.avgKmh != nil }) {
                ScatterChart(trips: counted.filter { $0.avgKmh != nil }, title: "Forbrug og fart", symbol: "speedometer",
                             xLabel: "gennemsnitsfart, km/t", x: { $0.avgKmh ?? 0 },
                             note: "Langsomme ture bruger mere pr. km om vinteren, fordi varmen kører, uanset hvor langt bilen kommer.")
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

/// The details of one trip, shown above a chart while it is touched.
private struct TripBubble: View {
    let trip: Trip
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trip.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(DK.locale)))
                .font(.caption.weight(.semibold))
            Text("\(DK.num(trip.km, 0)) km · brugte \(DK.num(trip.kwhPer100, 1)) · Maps \(DK.num(trip.mapsValue, 1)) kWh/100 km")
                .font(.caption2).monospacedDigit()
            HStack(spacing: 8) {
                Text((deviation(trip) >= 0 ? "+" : "") + "\(Int(deviation(trip).rounded())) %").foregroundStyle(hitColor(trip)).bold()
                if let c = trip.tempC { Text("\(DK.num(c, 0)) °C") }
                if let v = trip.avgKmh { Text("\(DK.num(v, 0)) km/t") }
            }
            .font(.caption2).monospacedDigit()
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

/// Placeholder line under a chart: the selected trip, or a hint to touch the chart.
private struct SelectionLine: View {
    let trip: Trip?
    let hint: String
    var body: some View {
        Group {
            if let t = trip { TripBubble(trip: t) } else {
                Label(hint, systemImage: "hand.tap").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: trip?.id)
    }
}

/// One bar per trip: how far the real consumption was from what Maps was told.
private struct AccuracyChart: View {
    let trips: [Trip]
    @State private var selected: String?

    private func key(_ i: Int) -> String { String(i) }
    private var selectedTrip: Trip? { selected.flatMap(Int.init).flatMap { trips.indices.contains($0) ? trips[$0] : nil } }

    var body: some View {
        let within = trips.filter { abs(deviation($0)) <= 5 }.count
        let span = max(15, (trips.map { abs(deviation($0)) }.max() ?? 15) + 5)
        Card(title: "Ramte Maps forbruget?", symbol: "target") {
            Chart {
                ForEach([-5.0, 5.0], id: \.self) { y in
                    RuleMark(y: .value("Grænse", y))
                        .foregroundStyle(Color.green.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ForEach(Array(trips.enumerated()), id: \.element.id) { i, t in
                    BarMark(x: .value("Tur", key(i)), y: .value("Afvigelse", deviation(t)))
                        .foregroundStyle(hitColor(t).opacity(selected == nil || selected == key(i) ? 1 : 0.35))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Nul", 0)).foregroundStyle(Color.secondary.opacity(0.6))
            }
            .chartXSelection(value: $selected)
            .chartYScale(domain: -span...span)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(x > 0 ? "+" : "")\(Int(x)) %") } }
                }
            }
            .frame(height: 170)
            SelectionLine(trip: selectedTrip, hint: "Træk hen over søjlerne for at se hver tur")
            Text("Ældste tur til venstre. Over nul brugte bilen mere, end Maps regnede med. \(within) af \(trips.count) ture ramte inden for ±5 % (mellem de grønne streger).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Used vs Maps per trip over time; scroll sideways for older trips, touch for details.
private struct OverTimeChart: View {
    let trips: [Trip]
    @State private var selectedDate: Date?

    private var selectedTrip: Trip? {
        guard let d = selectedDate else { return nil }
        return trips.min { abs($0.startDate.timeIntervalSince(d)) < abs($1.startDate.timeIntervalSince(d)) }
    }

    var body: some View {
        let top = (trips.flatMap { [$0.kwhPer100, $0.mapsValue] }.max() ?? 30) * 1.15
        Card(title: "Forbrug over tid", symbol: "chart.line.uptrend.xyaxis") {
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
                        .symbolSize(selectedTrip?.id == t.id ? 120 : 30)
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
            .chartXVisibleDomain(length: 14 * 24 * 3600)
            .chartScrollPosition(initialX: (trips.last?.startDate ?? .now).addingTimeInterval(-13 * 24 * 3600))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(DK.locale))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .frame(height: 190)
            SelectionLine(trip: selectedTrip, hint: "Rul til siden for ældre ture, tryk for detaljer")
            Text("kWh pr. 100 km. Jo tættere de to linjer ligger, jo bedre passer Maps' rækkevidde og ankomstprocent.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Consumption against one trip property (temperature or speed); touch for the nearest trip.
private struct ScatterChart: View {
    let trips: [Trip]
    let title: String
    let symbol: String
    let xLabel: String
    let x: (Trip) -> Double
    let note: String
    @State private var selectedX: Double?

    private var selectedTrip: Trip? {
        guard let v = selectedX else { return nil }
        return trips.min { abs(x($0) - v) < abs(x($1) - v) }
    }

    var body: some View {
        let xs = trips.map(x)
        let lo = (xs.min() ?? 0), hi = (xs.max() ?? 1)
        let pad = max(1, (hi - lo) * 0.08)
        let top = (trips.map(\.kwhPer100).max() ?? 30) * 1.15
        Card(title: title, symbol: symbol) {
            Chart {
                ForEach(trips) { t in
                    PointMark(x: .value(xLabel, x(t)), y: .value("kWh/100 km", t.kwhPer100))
                        .foregroundStyle(hitColor(t).opacity(selectedTrip == nil || selectedTrip?.id == t.id ? 0.9 : 0.3))
                        .symbolSize(selectedTrip?.id == t.id ? 160 : 55)
                }
                if let t = selectedTrip {
                    RuleMark(x: .value("Valgt", x(t))).foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .chartXSelection(value: $selectedX)
            .chartXScale(domain: (lo - pad)...(hi + pad))
            .chartYScale(domain: 0...top)
            .chartXAxisLabel(xLabel, alignment: .trailing)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
            HStack(spacing: 12) {
                ForEach([("Maps ramte", Color.green), ("brugte mere", Color.orange), ("brugte mindre", Color.blue)], id: \.0) { l in
                    HStack(spacing: 4) { Circle().fill(l.1).frame(width: 8, height: 8); Text(l.0) }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            SelectionLine(trip: selectedTrip, hint: "Træk hen over grafen for at se hver tur")
            Text(note).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
