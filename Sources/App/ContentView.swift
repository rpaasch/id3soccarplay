//
//  ContentView.swift
//  ID3Maps host app.
//
//  Shows the car's real state (fetched from the Worker), lets you save the
//  Worker status token once, and shows/exports the shared log (the log is how we
//  see what Apple Maps asked the extension).
//

import SwiftUI
import WidgetKit
import Charts
import UIKit
import Intents

struct ContentView: View {
    @State private var profile: VehicleProfile?
    @State private var loadError: String?
    @State private var live: VehicleState?
    @State private var liveNote = "Henter…"
    @State private var hasToken = SharedStore.string(.statusToken)?.isEmpty == false
    @State private var tokenInput = ""
    @State private var entries: [LogEntry] = []
    /// Set → the share sheet opens with exactly this file (sheet(item:) avoids the empty first sheet).
    @State private var exportFile: ExportFile?
    @State private var siriStatus = "unknown"
    @State private var trips: [Trip] = []
    @State private var tripsNote = ""
    @State private var bands: [TempBand] = []
    @State private var gpsOn = GPSRecorder.shared.enabled
    @State private var gpsNote = ""

    var body: some View {
        TabView {
            NavigationStack { carTab.navigationTitle("ID.3") }
                .tabItem { Label("Bil", systemImage: "car.fill") }
            NavigationStack { tripsTab.navigationTitle("Ture") }
                .tabItem { Label("Ture", systemImage: "road.lanes") }
            NavigationStack { chargingTab.navigationTitle("Ladning") }
                .tabItem { Label("Ladning", systemImage: "bolt.car.fill") }
            NavigationStack { moreTab.navigationTitle("Mere") }
                .tabItem { Label("Mere", systemImage: "gearshape") }
        }
        .tint(.teal)
        .onAppear { reload(); Task { await refreshLive() } }
        .task { await liveLoop() }
        .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
    }

    // MARK: Tabs

    private func scrollPage<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 14) { content() }
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { reload(); await Task { await refreshLive() }.value } // own task: SwiftUI cancels the refresh task when the view redraws
    }

    private var carTab: some View {
        scrollPage {
            if let s = live {
                // Hero: battery ring, range, status chips
                Card {
                    HStack(alignment: .center, spacing: 20) {
                        BatteryRing(soc: s.stateOfCharge, charging: s.isCharging)
                        VStack(alignment: .leading, spacing: 4) {
                            if let r = s.rangeKm {
                                Text("\(Int(r.rounded())) km").font(.system(.title, design: .rounded).bold()).monospacedDigit()
                                Text("rækkevidde ifølge bilen").font(.caption).foregroundStyle(.secondary)
                            }
                            Label(ageText(s.measuredAt), systemImage: "clock")
                                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 8)
                    chips(for: s)
                }
                if s.isCharging { chargingNowCard(s) }
                if let m = s.model { mapsCard(m) }
            } else {
                Card { Text(liveNote).foregroundStyle(.secondary) }
            }
            Text(liveNote).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func chips(for s: VehicleState) -> some View {
        let warm = s.model?.batteryWarm == true
        ViewThatFits {
            HStack { chipList(s, warm: warm) }
            VStack(alignment: .leading) { chipList(s, warm: warm) }
        }
    }

    @ViewBuilder private func chipList(_ s: VehicleState, warm: Bool) -> some View {
        if s.isCharging {
            StatusChip(text: "Lader" + (s.chargeKind.map { " \($0.uppercased())" } ?? "") + (s.minutesToFull.map { " · \($0) min" } ?? ""),
                       symbol: "bolt.fill", tint: .yellow)
        }
        if gpsOn { StatusChip(text: GPSRecorder.shared.isRecording ? "GPS måler" : "GPS klar", symbol: "location.fill", tint: .blue) }
        StatusChip(text: warm ? "Varmt batteri" : "Koldt batteri", symbol: warm ? "thermometer.sun.fill" : "snowflake", tint: warm ? .orange : .cyan)
    }

    /// Live charging: power now, time to full, and this session's power per SoC over Maps' curve.
    private func chargingNowCard(_ s: VehicleState) -> some View {
        Card(title: "Ladning nu", symbol: "bolt.fill") {
            HStack(spacing: 12) {
                stat("Effekt", s.chargePowerW.map { String(format: "%.0f kW", $0 / 1000) } ?? "–")
                stat("Til fuld", s.minutesToFull.map { "\($0) min" } ?? "–")
                stat("Type", (s.chargeKind ?? "?").uppercased())
            }
            let samples = (s.chargeSamples ?? []).sorted { $0.soc < $1.soc }
            let expected = profile.map { curvePoints(profile: $0, hints: s.model) } ?? []
            if samples.count >= 2 || !expected.isEmpty {
                Chart {
                    ForEach(expected) { pt in
                        LineMark(x: .value("Batteri", pt.soc), y: .value("kW", pt.kw), series: .value("Kurve", "Maps"))
                            .foregroundStyle(.gray.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    ForEach(Array(smoothed(samples).enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Batteri", p.0), y: .value("kW", p.1), series: .value("Kurve", "Nu"))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 3))
                    }
                    ForEach(samples, id: \.self) { x in
                        PointMark(x: .value("Batteri", x.soc * 100), y: .value("kW", x.kw))
                            .foregroundStyle(.green.opacity(0.35))
                            .symbolSize(18)
                    }
                    if let now = s.chargePowerW {
                        PointMark(x: .value("Batteri", s.stateOfCharge * 100), y: .value("kW", now / 1000))
                            .foregroundStyle(.yellow)
                            .symbolSize(120)
                            .annotation(position: .top) { Text("nu").font(.caption2.bold()) }
                    }
                }
                .chartXScale(domain: 0...100)
                .chartXAxisLabel("Batteri (%)")
                .chartYAxisLabel("kW")
                .frame(height: 200)
                Text("Grøn = denne ladning (målt). Stiplet grå = det Maps regner med.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 3-point moving average (the SoC-derived samples are noisy at 1 % resolution).
    private func smoothed(_ xs: [ChargeSample]) -> [(Double, Double)] {
        guard xs.count >= 3 else { return xs.map { ($0.soc * 100, $0.kw) } }
        return xs.indices.map { i in
            let lo = max(0, i - 1), hi = min(xs.count - 1, i + 1)
            let w = xs[lo...hi]
            return (xs[i].soc * 100, w.map(\.kw).reduce(0, +) / Double(w.count))
        }
    }

    /// What Maps is told about consumption, in one card: per speed, then why.
    private func mapsCard(_ m: ModelHints) -> some View {
        Card(title: "Det regner Maps med", symbol: "map") {
            let aux = m.auxPowerW ?? 500
            if let bins = m.consumptionBinsKwhPer100, bins.count == 10 {
                Text("Strømforbrug pr. 100 km" + (m.temperatureC.map { " ved \(DK.num($0, 0)) °C ude" } ?? "") + ", varme medregnet:")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    tile(DK.num(SpeedBinsChart.value(bins: bins, auxW: aux, index: 2), 0) + " kWh", "by, 50 km/t")
                    tile(DK.num(SpeedBinsChart.value(bins: bins, auxW: aux, index: 4), 0) + " kWh", "landevej, 90")
                    tile(DK.num(SpeedBinsChart.value(bins: bins, auxW: aux, index: 6), 0) + " kWh", "motorvej, 130")
                }
                SpeedBinsChart(bins: bins, auxW: aux)
            } else if let k = m.consumptionKwhPer100 {
                tile(DK.num(k) + " kWh", "pr. 100 km i snit")
            }
            Text(mapsFootnote(m)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.title2, design: .rounded).bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func mapsFootnote(_ m: ModelHints) -> String {
        var parts: [String] = []
        if let a = m.auxPowerW {
            parts.append("Varmen bruger \(DK.num(a / 1000)) kW hele tiden, så ved lav fart koster den mest pr. km.")
        }
        if let c = m.tripCalibration {
            let pct = Int(((c.factor - 1) * 100).rounded())
            if pct > 0 {
                parts.append("Tallene er \(pct) % højere end den rene beregning, fordi dine sidste \(c.n) ture (\(DK.num(c.km, 0)) km) viste, at bilen bruger så meget mere i virkeligheden.")
            } else if pct < 0 {
                parts.append("Tallene er \(-pct) % lavere end den rene beregning, fordi dine sidste \(c.n) ture (\(DK.num(c.km, 0)) km) viste, at bilen bruger mindre i virkeligheden.")
            }
        } else if m.consumptionSource != "trips" {
            parts.append("Bygger på bilens eget estimat plus en sikkerhedsmargen, indtil du har kørt et par længere ture.")
        }
        return parts.joined(separator: " ")
    }

    private var tripsTab: some View {
        scrollPage {
            if trips.isEmpty {
                Card { Text(tripsNote.isEmpty ? "Ingen ture endnu. En tur logges, når bilen har kørt mindst 5 km." : tripsNote).foregroundStyle(.secondary) }
            } else {
                if let c = live?.model?.tripCalibration {
                    Card(title: "Kalibrering", symbol: "dial.medium") {
                        let pct = Int(((c.factor - 1) * 100).rounded())
                        HStack(alignment: .center) {
                            Text("×" + DK.num(c.factor, 2))
                                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            Spacer()
                            Text("\(c.n) \(c.n == 1 ? "tur" : "ture") · \(DK.num(c.km, 0)) km")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        Text("Bilen bruger \(abs(pct)) % \(pct >= 0 ? "mere" : "mindre") strøm end ren fysik siger. Maps får forbruget ganget med dette tal. Det bygger på \(c.sourceText).")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !bands.isEmpty { bandsCard }
                let shown = Array(trips.prefix(20))
                let scale = (shown.flatMap { [$0.kwhPer100, $0.mapsValue] }.max() ?? 30) * 1.05
                ForEach(groupedByDay(shown)) { group in
                    Text(group.day).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    ForEach(group.trips) { TripCard(trip: $0, scale: scale) }
                }
                Text("Brugte = kWh pr. 100 km ud fra batteriets fald. Maps = det forbrug, Maps fik for samme fart og temperatur, med den kalibrering der gjaldt da. Ture under 20 km tæller ikke med, fordi batteriet melder i hele procent.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Every 5 °C band the car has been driven or charged in: its own factor and charge-curve status.
    private var bandsCard: some View {
        Card(title: "Temperaturbånd", symbol: "thermometer.snowflake") {
            Text("Bilen bruger forskelligt efter temperaturen. Hvert bånd husker sine egne seneste 15 ture, så vinteren stadig er kendt til foråret. Maps bruger båndet for dagens temperatur.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(bands) { b in bandRow(b) }
            }
            HStack(spacing: 14) {
                Text("Ladekurve lært:").foregroundStyle(.secondary)
                Label("varmt batteri", systemImage: "bolt.fill").foregroundStyle(.orange)
                Label("koldt", systemImage: "bolt.fill").foregroundStyle(.cyan)
            }
            .font(.caption2)
        }
    }

    private func bandRow(_ b: TempBand) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(b.band) til \(b.band + 5) °C")
                    .font(.callout.weight(b.current ? .semibold : .regular)).monospacedDigit()
                if b.current { Text("i dag").font(.caption2.bold()).foregroundStyle(.teal) }
            }
            .fixedSize()
            Spacer(minLength: 8)
            if let f = b.factor {
                Text("×" + DK.num(f, 2)).font(.callout.bold()).monospacedDigit().fixedSize()
                Text("\(DK.num(b.km, 0)) km").font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            } else {
                Text(b.km > 0 ? "\(DK.num(b.km, 0)) km – for lidt" : "ingen ture").font(.caption).foregroundStyle(.tertiary).fixedSize()
            }
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill").foregroundStyle(b.chargeWarm > 0 ? Color.orange : Color.clear)
                Image(systemName: "bolt.fill").foregroundStyle(b.chargeCold > 0 ? Color.cyan : Color.clear)
            }
            .font(.caption)
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(b.current ? Color.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private struct DayGroup: Identifiable { let day: String; var trips: [Trip]; var id: String { day } }

    private func groupedByDay(_ trips: [Trip]) -> [DayGroup] {
        var out: [DayGroup] = []
        for t in trips {
            let d = DK.day(t.startDate)
            if out.last?.day == d { out[out.count - 1].trips.append(t) } else { out.append(DayGroup(day: d, trips: [t])) }
        }
        return out
    }

    private var chargingTab: some View {
        scrollPage {
            if let p = profile {
                let m = live?.model
                let points = curvePoints(profile: p, hints: m)
                Card(title: "Sådan regner Maps med, at bilen lader", symbol: "chart.xyaxis.line") {
                    Text("Kurven viser, hvor mange kW bilen tager imod ved hver batteriprocent på en hurtiglader. Maps bruger den til at regne ladetid og ladestop ud.")
                        .font(.callout).foregroundStyle(.secondary)
                    if points.isEmpty {
                        Text("Ingen kurve.").foregroundStyle(.secondary)
                    } else {
                        Chart(points) { pt in
                            AreaMark(x: .value("Batteri", pt.soc), y: .value("kW", pt.kw))
                                .foregroundStyle(.teal.opacity(0.15).gradient)
                            LineMark(x: .value("Batteri", pt.soc), y: .value("kW", pt.kw))
                                .foregroundStyle(.teal)
                            PointMark(x: .value("Batteri", pt.soc), y: .value("kW", pt.kw))
                                .foregroundStyle(pt.learned ? Color.green : Color.gray)
                                .symbolSize(pt.learned ? 60 : 25)
                        }
                        .chartXScale(domain: 0...100)
                        .chartXAxis {
                            AxisMarks(values: [0.0, 20, 40, 60, 80, 100]) { v in
                                AxisGridLine()
                                AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x)) %") } }
                            }
                        }
                        .chartYAxisLabel("kW")
                        .frame(height: 200)
                        HStack(spacing: 16) {
                            legend(.green, "målt ved dine ladninger")
                            legend(.gray, "standardkurve")
                        }
                        .font(.caption)

                        let capacityKwh = p.adjusted(with: m).profile.battery.usableCapacityWh / 1000
                        HStack(spacing: 12) {
                            if let mins = chargeMinutes(from: 10, to: 80, points: points, capacityKwh: capacityKwh) {
                                stat("fra 10 til 80 %", "\(Int(mins.rounded())) min")
                            }
                            if let peak = points.map(\.kw).max() { stat("højeste effekt", "\(Int(peak.rounded())) kW") }
                        }
                        .padding(.top, 4)
                        Text(chargeConditions(m))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let m {
                    Card(title: "Det har appen lært", symbol: "brain") {
                        let curve = m.chargeCurveKw ?? []
                        let learned = curve.compactMap { $0 }.count
                        if learned > 0 {
                            Text("\(learned) af \(max(curve.count, 11)) punkter på kurven er målt ved dine egne hurtigladninger med \(m.chargeCurveWarm == true ? "varmt" : "koldt") batteri (\(m.chargeSessions ?? 0) \((m.chargeSessions ?? 0) == 1 ? "ladning" : "ladninger") i alt). Resten er standardkurven.")
                                .font(.callout)
                            if let gaps = missingRanges(curve) {
                                Text("Mangler stadig: \(gaps). De punkter lærer appen, næste gang du lader i det område.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Der er endnu ingen målinger ved den temperatur. Maps bruger standardkurven, indtil du har hurtigladet.")
                                .font(.callout)
                        }
                        if let c = m.capacityKwhNet {
                            KeyValue(key: "Brugbart batteri", value: "\(Int(c)) kWh")
                        }
                        Text("Appen lærer automatisk, hver gang bilen hurtiglader. Varmt batteri (lige efter kørsel) og koldt batteri læres hver for sig, fordi et koldt batteri lader langsommere.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    /// The conditions the curve applies to, in plain words.
    private func chargeConditions(_ m: ModelHints?) -> String {
        var parts: [String] = []
        if let m {
            parts.append(m.chargeCurveWarm == true ? "Gælder et varmt batteri" : "Gælder et koldt batteri")
            if let t = m.temperatureC { parts[0] += " ved \(DK.num(t, 0)) °C ude" }
            parts[0] += "."
            if let x = m.chargePowerScale, x < 0.99 {
                parts.append("Kulden trækker effekten ned med \(Int(((1 - x) * 100).rounded())) %.")
            }
        }
        parts.append("Tiden forudsætter, at laderen kan levere fuld effekt. Deler du laderen med en anden bil, går det langsommere.")
        return parts.joined(separator: " ")
    }

    /// Battery ranges whose curve points are not learned yet, e.g. "0–10 % og 80–100 %".
    private func missingRanges(_ curve: [Double?]) -> String? {
        guard curve.count >= 2 else { return nil }
        let step = 100 / (curve.count - 1)
        var ranges: [(Int, Int)] = []
        for (i, v) in curve.enumerated() where v == nil {
            let pct = i * step
            if let last = ranges.last, last.1 == pct - step { ranges[ranges.count - 1].1 = pct } else { ranges.append((pct, pct)) }
        }
        guard !ranges.isEmpty else { return nil }
        let texts = ranges.map { $0.0 == $0.1 ? "\($0.0) %" : "\($0.0)–\($0.1) %" }
        return texts.count == 1 ? texts[0] : texts.dropLast().joined(separator: ", ") + " og " + texts.last!
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "0.1.0 (build 84)" — the build number is the GitHub Actions run that made the IPA.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (build \(b))"
    }

    private var moreTab: some View {
        List {
            gpsSection
            connectionSection
            actionSection
            Section {
                NavigationLink { LogView(entries: entries) } label: { Label("Log (\(entries.count))", systemImage: "doc.text.magnifyingglass") }
                if let p = profile { row("Bil i Maps", "\(p.vehicle.mapsMake) \(p.vehicle.mapsModel) (maskering)") }
                row("Siri-tilladelse", siriStatus)
            }
            Section("Om appen") {
                row("Version", appVersion)
            }
        }
        .refreshable { reload(); await Task { await refreshLive() }.value } // own task: SwiftUI cancels the refresh task when the view redraws
    }

    private var gpsSection: some View {
        Section("GPS-måling af kørsel") {
            Toggle("Mål fart og højde med GPS", isOn: $gpsOn)
                .onChange(of: gpsOn) { _, on in
                    GPSRecorder.shared.enabled = on
                    refreshGPSNote()
                }
            if gpsOn {
                row("Tilladelse", GPSRecorder.shared.authorizationText)
                row("Optager nu", GPSRecorder.shared.isRecording ? "ja" : "nej")
                if !gpsNote.isEmpty { Text(gpsNote).font(.footnote).foregroundStyle(.secondary) }
            }
            Text("Positioner bliver på telefonen. Kun tid og km pr. fartinterval samt meter op og ned sendes til Workeren. Vælg \"Altid\" som placeringstilladelse, så turen måles uden at appen er åben.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func refreshGPSNote() {
        gpsNote = GPSRecorder.shared.lastUploadNote
    }

    private var connectionSection: some View {
        Section("Forbindelse til Workeren") {
            if hasToken {
                row("Status-token", "gemt ✓")
            }
            SecureField(hasToken ? "Nyt status-token (valgfrit)" : "Indsæt status-token", text: $tokenInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Gem token og hent status") {
                let t = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                SharedStore.setString(t, for: .statusToken)
                SharedLog.shared.log("status token saved", category: "app")
                tokenInput = ""
                hasToken = true
                Task { await refreshLive() }
            }
        }
    }

    private var actionSection: some View {
        Section("Handlinger") {
            Button("Anmod om Siri-tilladelse") { requestSiri() }
            Button("Send testinteraktion til Maps/Siri") { donateTestInteraction() }
            Button("Hent status nu") { Task { await refreshLive() } }
            Button("Opdater log") { reload() }
            Button("Eksportér log…") { exportLog() }
            Button("Ryd log", role: .destructive) {
                SharedLog.shared.clear(); reload()
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }

    /// While the app is open: refetch every 60 s (every 30 s while charging).
    private func liveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(live?.isCharging == true ? 30 : 60))
            if Task.isCancelled { return }
            await Task { await refreshLive() }.value
        }
    }

    private func ageText(_ d: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(d) / 60)
        if minutes < 1 { return "lige nu" }
        if minutes < 90 { return "for \(minutes) min siden" }
        return "for \(minutes / 60) t \(minutes % 60) min siden"
    }

    // MARK: Actions

    private func reload() {
        do { profile = try VehicleProfile.load(); loadError = nil }
        catch { loadError = "\(error)" }
        entries = SharedLog.shared.entries()
        siriStatus = siriStatusText(INPreferences.siriAuthorizationStatus())
    }

    private func refreshLive() async {
        guard SharedStore.string(.statusToken)?.isEmpty == false else {
            liveNote = "Indsæt status-tokenet nedenfor for at hente bilens tal."
            return
        }
        do {
            let s = try await StatusClient.fetch(timeout: 8)
            SharedStore.setCodable(s, for: .lastState)
            let changed = live.map { Int($0.stateOfCharge * 100) != Int(s.stateOfCharge * 100) || $0.isCharging != s.isCharging } ?? true
            live = s
            if changed { WidgetCenter.shared.reloadAllTimelines() }
            await DriveEvents.flush()
            liveNote = "Hentet fra Workeren."
            if let r = try? await TripsClient.fetch() { trips = r.trips; bands = r.bands ?? []; tripsNote = "" } else { tripsNote = "Kunne ikke hente turene." }
            await GPSRecorder.shared.flushQueue()
            refreshGPSNote()
            if Date().timeIntervalSince(s.measuredAt) > 1800 && !s.isCharging {
                liveNote += " Tidspunktet er, hvornår bilen sidst meldte til VW. Det er normalt, når den holder parkeret."
            }
        } catch {
            // A cancelled request is not a failure; keep what is shown.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            SharedLog.shared.log("app refresh failed: \(error)", category: "app")
            let why: String = switch (error as? URLError)?.code {
            case .notConnectedToInternet?, .networkConnectionLost?: "ingen forbindelse"
            case .timedOut?: "Workeren svarede for langsomt"
            default: "fejl – se loggen"
            }
            if let cached: VehicleState = SharedStore.codable(.lastState) {
                live = cached
                liveNote = "Kunne ikke hente friske tal (\(why)). Viser sidste kendte måling."
            } else {
                liveNote = "Ingen data endnu (\(why))."
            }
        }
        entries = SharedLog.shared.entries()
    }

    private func requestSiri() {
        INPreferences.requestSiriAuthorization { status in
            let text = siriStatusText(status)
            SharedLog.shared.log("Siri auth -> \(text)", category: "app")
            Task { @MainActor in self.siriStatus = text }
        }
    }

    private func donateTestInteraction() {
        guard let p = profile else { return }
        let intent = INListCarsIntent()
        let response = INListCarsIntentResponse(code: .success, userActivity: nil)
        response.cars = [MapsCar.make(profile: p)]
        let interaction = INInteraction(intent: intent, response: response)
        interaction.donate { error in
            let msg = error.map { "donate error: \($0)" } ?? "donated INListCarsIntent"
            SharedLog.shared.log(msg, category: "app")
            Task { @MainActor in self.reload() }
        }
    }

    private func exportLog() {
        let text = SharedLog.shared.exportText()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id3maps-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportFile = ExportFile(url: url)
        } catch {
            SharedLog.shared.log("export failed: \(error)", category: "app")
        }
    }
}

/// Free (nonisolated) helper so it can be called from background completion
/// handlers under strict concurrency.
private func siriStatusText(_ s: INSiriAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

/// UIKit share sheet bridge.
struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}


// MARK: - Charging curve helpers

private struct CurvePoint: Identifiable {
    let id: Int
    let soc: Double      // percent
    let kw: Double
    let learned: Bool
}

/// The curve exactly as Maps receives it (baseline adapted with the live hints).
private func curvePoints(profile: VehicleProfile, hints: ModelHints?) -> [CurvePoint] {
    let params = profile.adjusted(with: hints).profile.chargingContract.vehicleParameters
    guard let energy = params.numbers("vehicle_energy_axis_wh"),
          let watts = params.numbers("vehicle_charge_axis_w"),
          energy.count == watts.count, let capacity = energy.last, capacity > 0
    else { return [] }
    let learned = hints?.chargeCurveKw ?? []
    return energy.indices.map { i in
        CurvePoint(id: i, soc: energy[i] / capacity * 100, kw: watts[i] / 1000,
                   learned: i < learned.count && learned[i] != nil)
    }
}

/// Minutes to charge from `a` % to `b` % along the curve (linear interpolation).
private func chargeMinutes(from a: Double, to b: Double, points: [CurvePoint], capacityKwh: Double) -> Double? {
    guard points.count > 1, b > a else { return nil }
    func power(at soc: Double) -> Double {
        for i in 1..<points.count where soc <= points[i].soc {
            let p0 = points[i - 1], p1 = points[i]
            let f = p1.soc == p0.soc ? 0 : (soc - p0.soc) / (p1.soc - p0.soc)
            return p0.kw + (p1.kw - p0.kw) * f
        }
        return points.last?.kw ?? 1
    }
    let steps = 70
    var minutes = 0.0
    for s in 0..<steps {
        let s0 = a + (b - a) * Double(s) / Double(steps)
        let s1 = a + (b - a) * Double(s + 1) / Double(steps)
        minutes += (s1 - s0) / 100 * capacityKwh / max(power(at: (s0 + s1) / 2), 1) * 60
    }
    return minutes
}
