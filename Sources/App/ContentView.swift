//
//  ContentView.swift
//  ID3Maps host app.
//
//  Shows the car's real state (fetched from the Worker), lets you save the
//  Worker status token once, and shows/exports the shared log (the log is how we
//  see what Apple Maps asked the extension).
//

import SwiftUI
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
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var siriStatus = "unknown"
    @State private var trips: [Trip] = []
    @State private var tripsNote = ""
    @State private var gpsOn = GPSRecorder.shared.enabled
    @State private var gpsNote = ""
    @State private var obdOn = OBDManager.shared.enabled
    @State private var obd = OBDManager.shared.status()

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
        .sheet(isPresented: $showShare) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
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
                    HStack(alignment: .center, spacing: 18) {
                        BatteryRing(soc: s.stateOfCharge, charging: s.isCharging)
                        VStack(alignment: .leading, spacing: 8) {
                            if let r = s.rangeKm {
                                Text("\(Int(r.rounded())) km").font(.title.bold()).monospacedDigit()
                                Text("rækkevidde (bilens bud)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(ageText(s.measuredAt)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    chips(for: s)
                }
                if let m = s.model {
                    consumptionCard(m)
                    temperatureCard(m)
                }
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
        if obdOn, obd.validated { StatusChip(text: "OBD live", symbol: "antenna.radiowaves.left.and.right", tint: .green) }
        if gpsOn { StatusChip(text: GPSRecorder.shared.isRecording ? "GPS måler" : "GPS klar", symbol: "location.fill", tint: .blue) }
        StatusChip(text: warm ? "Varmt batteri" : "Koldt batteri", symbol: warm ? "thermometer.sun.fill" : "snowflake", tint: warm ? .orange : .cyan)
    }

    private func consumptionCard(_ m: ModelHints) -> some View {
        Card(title: "Forbrug i Maps", symbol: "speedometer") {
            if let k = m.consumptionKwhPer100 {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.1f", k)).font(.largeTitle.bold()).monospacedDigit()
                    Text("kWh/100 km i snit").foregroundStyle(.secondary)
                }
            }
            if let bins = m.consumptionBinsKwhPer100, bins.count == 10 {
                SpeedBinsChart(bins: bins, auxW: m.auxPowerW ?? 500)
            }
            let source = switch m.consumptionSource ?? "" {
            case "trips": "lært af dine ture"
            case "learned": "lært"
            default: "bilens estimat + margen"
            }
            KeyValue(key: "Kilde", value: source)
            if let c = m.tripCalibration {
                KeyValue(key: "Kalibrering", value: String(format: "×%.2f · %d ture · %.0f km", c.factor, c.n, c.km))
            }
            if let a = m.auxPowerW { KeyValue(key: "Varme m.m.", value: String(format: "%.1f kW", a / 1000)) }
        }
    }

    private func temperatureCard(_ m: ModelHints) -> some View {
        Card(title: "Temperatur", symbol: "thermometer.medium") {
            if let t = m.temperatureC { KeyValue(key: "Ude", value: String(format: "%.1f °C", t)) }
            if obdOn, let bt = obd.decoded.first(where: { $0.label == "Batteritemperatur" }) {
                KeyValue(key: "Batteri (OBD)", value: bt.value)
            }
            if let x = m.chargePowerScale {
                KeyValue(key: "Ladeeffekt i kulden", value: String(format: "×%.2f", x))
            }
        }
    }

    private var tripsTab: some View {
        scrollPage {
            if trips.isEmpty {
                Card { Text(tripsNote.isEmpty ? "Ingen ture endnu. En tur logges, når bilen har kørt mindst 5 km." : tripsNote).foregroundStyle(.secondary) }
            } else {
                if let c = live?.model?.tripCalibration {
                    Card(title: "Kalibrering", symbol: "dial.medium") {
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "×%.2f", c.factor)).font(.largeTitle.bold()).monospacedDigit()
                            Text("bilen bruger \(Int(((c.factor - 1) * 100).rounded())) % mere end ren fysik")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Text(String(format: "Ud fra %d ture og %.0f km ved samme temperatur.", c.n, c.km))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(trips.prefix(20)) { TripCard(trip: $0) }
                Text("×1,00 = bilen brugte præcis det, modellen (og dermed Maps) regnede med. Korte ture er usikre, fordi batteriet melder i hele procent.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var chargingTab: some View {
        scrollPage {
            if let p = profile {
                let points = curvePoints(profile: p, hints: live?.model)
                Card(title: "Ladekurve (det Maps får)", symbol: "chart.xyaxis.line") {
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
                        .chartXAxisLabel("Batteri (%)")
                        .chartYAxisLabel("kW")
                        .frame(height: 220)
                        let capacityKwh = p.adjusted(with: live?.model).profile.battery.usableCapacityWh / 1000
                        HStack(spacing: 12) {
                            if let m = chargeMinutes(from: 10, to: 80, points: points, capacityKwh: capacityKwh) {
                                stat("10 → 80 %", "\(Int(m.rounded())) min")
                            }
                            if let peak = points.map(\.kw).max() { stat("Top", "\(Int(peak.rounded())) kW") }
                        }
                        Text("Grønne punkter er lært af dine egne hurtigladninger.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let m = live?.model {
                    Card(title: "Det er lært", symbol: "brain") {
                        let bins = (m.chargeCurveKw ?? []).compactMap { $0 }.count
                        KeyValue(key: "Kurve", value: bins > 0 ? "\(bins)/11 punkter, \(m.chargeCurveWarm == true ? "varmt" : "koldt") batteri" : "endnu ikke lært")
                        KeyValue(key: "Ladninger", value: "\(m.chargeSessions ?? 0)")
                        if let c = m.capacityKwhNet { KeyValue(key: "Batteri (netto)", value: "\(Int(c)) kWh") }
                    }
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var moreTab: some View {
        List {
            gpsSection
            obdSection
            connectionSection
            actionSection
            Section {
                NavigationLink { LogView(entries: entries) } label: { Label("Log (\(entries.count))", systemImage: "doc.text.magnifyingglass") }
                if let p = profile { row("Bil i Maps", "\(p.vehicle.mapsMake) \(p.vehicle.mapsModel) (maskering)") }
                row("Siri-tilladelse", siriStatus)
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

    private var obdSection: some View {
        Section("OBD-dongle (live batteriprocent)") {
            Toggle("Brug OBD-dongle", isOn: $obdOn)
                .onChange(of: obdOn) { _, on in
                    OBDManager.shared.enabled = on
                    obd = OBDManager.shared.status()
                }
            if obdOn {
                row("Status", obd.state)
                if let d = obd.device { row("Dongle", d) }
                if let p = obd.lastSocPct { row("Batteri (live)", String(format: "%.1f %%", p)) }
                row("Kontrolleret mod Smartcar", obd.validated ? "ja" : "ikke endnu")
                if let raw = obd.lastRaw { Text("Rå: \(raw)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                ForEach(obd.decoded) { d in row(d.label, d.value) }
                if let c = obd.calibration { Text("Kalibrering: \(c)").font(.caption).foregroundStyle(.secondary) }
                if let f = obd.firmware { row("Firmware", f) }
                if let v = obd.volt12 { row("12 V-batteri", v) }
                if let t = obd.lastAnswer { row("Sidste svar", t.formatted(date: .omitted, time: .standard)) }
                if obd.okCount + obd.failCount > 0 { row("Svar ok / fejl", "\(obd.okCount) / \(obd.failCount)") }
                if !obd.extras.isEmpty {
                    DisclosureGroup("Ekstra batteridata (rå, ikke tolket endnu)") {
                        ForEach(obd.extras) { x in
                            Text("\(x.did): \(x.hex)").font(.caption.monospaced())
                        }
                    }
                }
                Button("Scan batteriets data (1–2 min, bilen tændt)") {
                    OBDManager.shared.runScan()
                }
                if let p = obd.scanProgress { row("Scanning", p) }
                Button("Kør OBD-test (logger svar)") {
                    OBDManager.shared.runDiagnostics()
                }
                Button("Opdater OBD-status") { obd = OBDManager.shared.status() }
            }
            Text("Tænd bilen og luk andre apps, der bruger donglen (BimmerCode, Car Scanner o.l.). Live-tallet bruges kun i Maps, når det passer med Smartcar (højst 4 procentpoint forskel).")
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
            live = s
            liveNote = "Hentet fra Workeren."
            if let r = try? await TripsClient.fetch() { trips = r.trips; tripsNote = "" } else { tripsNote = "Kunne ikke hente turene." }
            await GPSRecorder.shared.flushQueue()
            refreshGPSNote()
            obd = OBDManager.shared.status()
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
            exportURL = url
            showShare = true
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
