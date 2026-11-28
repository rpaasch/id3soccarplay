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

/// Four charts over all trips: how close Maps was, consumption over time, and consumption
/// against temperature and speed. Two columns on wide screens (the foldable's inner display).
struct TripCharts: View {
    let trips: [Trip]

    private var chrono: [Trip] { trips.sorted { $0.start < $1.start } }
    private var counted: [Trip] { chrono.filter(\.isCounted) }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14, alignment: .top)], spacing: 14) {
            if counted.count >= 2 { accuracyCard }
            if counted.count >= 2 { overTimeCard }
            if counted.contains(where: { $0.tempC != nil }) { temperatureCard }
            if counted.contains(where: { $0.avgKmh != nil }) { speedCard }
        }
    }

    // MARK: Maps accuracy per trip

    private func pct(_ t: Trip) -> Double { (t.vsMaps - 1) * 100 }

    private func accuracyColor(_ p: Double) -> Color {
        abs(p) <= 5 ? .green : (p > 0 ? .orange : .blue)
    }

    private var accuracyCard: some View {
        let shown = Array(counted.suffix(30))
        let within = shown.filter { abs(pct($0)) <= 5 }.count
        return Card(title: "Ramte Maps forbruget?", symbol: "target") {
            Chart {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    BarMark(x: .value("Tur", i + 1), y: .value("Afvigelse", pct(t)), width: .ratio(0.7))
                        .foregroundStyle(accuracyColor(pct(t)))
                }
                RuleMark(y: .value("Nul", 0)).foregroundStyle(.secondary)
                ForEach([-5.0, 5.0], id: \.self) { y in
                    RuleMark(y: .value("Grænse", y))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x)) %") } }
                }
            }
            .frame(height: 150)
            Text("Hver søjle er en tur, ældste til venstre. Over nul brugte bilen mere, end Maps regnede med. \(within) af \(shown.count) ture ramte inden for ±5 % (mellem de grønne streger).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Used vs Maps over time

    private var overTimeCard: some View {
        let shown = Array(counted.suffix(30))
        return Card(title: "Forbrug over tid", symbol: "chart.line.uptrend.xyaxis") {
            Chart {
                ForEach(shown) { t in
                    LineMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.kwhPer100), series: .value("Hvad", "Brugte"))
                        .foregroundStyle(by: .value("Hvad", "Brugte"))
                    PointMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.kwhPer100))
                        .foregroundStyle(by: .value("Hvad", "Brugte"))
                        .symbolSize(20)
                    LineMark(x: .value("Dato", t.startDate), y: .value("kWh/100 km", t.mapsValue), series: .value("Hvad", "Maps"))
                        .foregroundStyle(by: .value("Hvad", "Maps"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
            }
            .chartForegroundStyleScale(["Brugte": Color.primary, "Maps": Color.teal])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxisLabel("kWh/100 km")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(DK.locale))
                }
            }
            .frame(height: 170)
            Text("Jo tættere de to linjer ligger, jo bedre passer Maps' rækkevidde og ankomstprocent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Consumption vs temperature / speed

    private var temperatureCard: some View {
        let shown = counted.filter { $0.tempC != nil }
        return Card(title: "Forbrug og temperatur", symbol: "thermometer.medium") {
            Chart(shown) { t in
                PointMark(x: .value("°C", t.tempC ?? 0), y: .value("kWh/100 km", t.kwhPer100))
                    .foregroundStyle(accuracyColor(pct(t)))
                    .symbolSize(max(20, min(160, t.km * 2)))
            }
            .chartXAxisLabel("°C")
            .chartYAxisLabel("kWh/100 km")
            .frame(height: 170)
            Text("Hver prik er en tur; større prik = længere tur. Farven viser, om Maps ramte (grøn), tog for lidt (orange) eller for meget (blå).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var speedCard: some View {
        let shown = counted.filter { $0.avgKmh != nil }
        return Card(title: "Forbrug og fart", symbol: "speedometer") {
            Chart(shown) { t in
                PointMark(x: .value("km/t", t.avgKmh ?? 0), y: .value("kWh/100 km", t.kwhPer100))
                    .foregroundStyle(by: .value("Temperatur", tempBucket(t.tempC)))
                    .symbolSize(max(20, min(160, t.km * 2)))
            }
            .chartForegroundStyleScale(["under 0 °C": Color.blue, "0–5 °C": Color.cyan, "5–10 °C": Color.teal, "over 10 °C": Color.orange, "ukendt": Color.gray])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxisLabel("gennemsnitsfart, km/t")
            .chartYAxisLabel("kWh/100 km")
            .frame(height: 170)
            Text("Langsomme ture bruger mere pr. km om vinteren, fordi varmen kører, uanset hvor langt bilen kommer.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func tempBucket(_ c: Double?) -> String {
        guard let c else { return "ukendt" }
        switch c {
        case ..<0: return "under 0 °C"
        case ..<5: return "0–5 °C"
        case ..<10: return "5–10 °C"
        default: return "over 10 °C"
        }
    }
}
