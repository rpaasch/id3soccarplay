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
        NavigationStack {
            List {
                statusSection
                chargeCurveSection
                tripsSection
                gpsSection
                obdSection
                connectionSection
                actionSection
                logSection
            }
            .navigationTitle("ID.3 Maps")
            .onAppear { reload(); Task { await refreshLive() } }
            .refreshable { reload(); await refreshLive() }
            .sheet(isPresented: $showShare) {
                if let url = exportURL { ShareSheet(items: [url]) }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Bilens tilstand") {
            if let s = live {
                row("SoC", "\(Int((s.stateOfCharge * 100).rounded())) %")
                row("Rækkevidde", s.rangeKm.map { "\(Int($0.rounded())) km" } ?? "–")
                row("Lader", s.isCharging
                    ? "ja" + (s.chargeKind.map { " (\($0.uppercased()))" } ?? "")
                        + (s.minutesToFull.map { ", \($0) min til fuld" } ?? "")
                    : "nej")
                row("Målt", ageText(s.measuredAt))
                if let m = s.model {
                    if let c = m.capacityKwhNet { row("Batteri (netto)", "\(Int(c)) kWh") }
                    if let k = m.consumptionKwhPer100 {
                        let label = m.consumptionSource == "trips" ? "Forbrug (lært af ture)"
                            : m.consumptionSource == "learned" ? "Forbrug (lært)" : "Forbrug (bilens estimat)"
                        row(label, String(format: "%.1f kWh/100 km", k))
                    }
                    if m.consumptionSource == "learned", let km = m.learnedKm { row("Lært over", "\(Int(km)) km") }
                    if let mode = m.consumptionShapeMode {
                        let text: String = switch mode {
                        case "trips": "fysikmodel, kalibreret af dine ture"
                        case "physics": "fysikmodel (bilens estimat + margen)"
                        case "learned": "lært"
                        default: "test: \(mode)"
                        }
                        row("Forbrug efter fart", text)
                    }
                    if let c = m.tripCalibration {
                        row("Kalibrering", String(format: "×%.2f (%d ture, %.0f km)", c.factor, c.n, c.km))
                    }
                    if let t = m.temperatureC { row("Udetemperatur", String(format: "%.1f °C", t)) }
                    if let x = m.chargePowerScale {
                        row("Ladeeffekt", String(format: "×%.2f (×1,00 = kurven ved %.0f °C)", x, m.referenceTempC ?? 6))
                    }
                    let bins = (m.chargeCurveKw ?? []).compactMap { $0 }.count
                    let kind = m.chargeCurveWarm == true ? "varmt batteri" : "koldt batteri"
                    row("Ladekurve", bins > 0 ? "lært, \(kind): \(bins)/11 punkter (\(m.chargeSessions ?? 0) ladninger)" : "endnu ikke lært")
                    if let w = m.batteryWarm { row("Batteri", w ? "varmt (kørt inden for 45 min)" : "koldt") }
                }
            }
            Text(liveNote).font(.footnote).foregroundStyle(.secondary)
            if let p = profile {
                row("Bil i Maps", "\(p.vehicle.mapsMake) \(p.vehicle.mapsModel) (maskering)")
            } else if let e = loadError {
                Text("Kunne ikke læse id3.json: \(e)").foregroundStyle(.red)
            }
            row("Siri-tilladelse", siriStatus)
        }
    }

    private var chargeCurveSection: some View {
        Section("Ladekurve (det Maps får)") {
            if let p = profile {
                let points = curvePoints(profile: p, hints: live?.model)
                if points.isEmpty {
                    Text("Ingen kurve.").foregroundStyle(.secondary)
                } else {
                    Chart(points) { pt in
                        LineMark(x: .value("Batteriniveau", pt.soc), y: .value("kW", pt.kw))
                            .foregroundStyle(.gray)
                        PointMark(x: .value("Batteriniveau", pt.soc), y: .value("kW", pt.kw))
                            .foregroundStyle(pt.learned ? Color.green : Color.gray)
                    }
                    .chartXScale(domain: 0...100)
                    .chartXAxisLabel("Batteriniveau (%)")
                    .chartYAxisLabel("kW")
                    .frame(height: 200)
                    let capacityKwh = p.adjusted(with: live?.model).profile.battery.usableCapacityWh / 1000
                    if let m = chargeMinutes(from: 10, to: 80, points: points, capacityKwh: capacityKwh) {
                        row("10 → 80 %", "ca. \(Int(m.rounded())) min")
                    }
                    if let peak = points.map(\.kw).max() {
                        row("Spids", "\(Int(peak.rounded())) kW")
                    }
                    Text("Grønne punkter er lært af dine egne hurtigladninger. Grå er skøn: den lærte kurve forlænget med grundkurvens form, eller grundkurven justeret efter udetemperaturen, hvis intet er lært.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tripsSection: some View {
        Section("Ture (forudsagt mod faktisk)") {
            if trips.isEmpty {
                Text(tripsNote.isEmpty ? "Ingen ture endnu. En tur logges, når bilen har kørt mindst 5 km og holdt stille i 10 min." : tripsNote)
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(trips.prefix(15)) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(t.startDate.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(String(format: "%.0f km", t.km)).foregroundStyle(.secondary)
                        }
                        Text(String(format: "Faktisk %.1f · forudsagt %.1f kWh/100 km (×%.2f)", t.kwhPer100, t.predictedPer100, t.ratio))
                            .font(.callout)
                        Text([
                            String(format: "%.0f → %.0f %%", t.socFrom * 100, t.socTo * 100),
                            t.tempC.map { String(format: "%.1f °C", $0) },
                            t.avgKmh.map { String(format: "snit %.0f km/t", $0) },
                            t.cold == true ? "koldstart" : nil,
                        ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("×1,00 betyder, at bilen brugte præcis det, modellen (og dermed Maps) regnede med. Over 1 = mere end forudsagt.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
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

    private var logSection: some View {
        Section("Log (\(entries.count))") {
            if entries.isEmpty {
                Text("Ingen linjer endnu.").foregroundStyle(.secondary)
            } else {
                ForEach(entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.message).font(.callout)
                        Text("\(e.date.formatted(date: .omitted, time: .standard)) · \(e.source.rawValue)/\(e.category)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
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
            if let cached: VehicleState = SharedStore.codable(.lastState) {
                live = cached
                liveNote = "Workeren svarede ikke (\(error)). Viser sidste kendte måling."
            } else {
                liveNote = "Ingen data: \(error)"
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
