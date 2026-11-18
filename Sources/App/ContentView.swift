//
//  ContentView.swift
//  ID3Maps host app.
//
//  Shows the car's real state (fetched from the Worker), lets you save the
//  Worker status token once, and shows/exports the shared log (the log is how we
//  see what Apple Maps asked the extension).
//

import SwiftUI
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

    var body: some View {
        NavigationStack {
            List {
                statusSection
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
                        let label = m.consumptionSource == "learned" ? "Forbrug (lært)" : "Forbrug (bilens estimat)"
                        row(label, String(format: "%.1f kWh/100 km", k))
                    }
                    if m.consumptionSource == "learned", let km = m.learnedKm { row("Lært over", "\(Int(km)) km") }
                    if let t = m.temperatureC { row("Udetemperatur", String(format: "%.1f °C", t)) }
                    if let x = m.chargePowerScale { row("Ladeeffekt vs. reference", String(format: "×%.2f", x)) }
                    let bins = (m.chargeCurveKw ?? []).compactMap { $0 }.count
                    row("Ladekurve", bins > 0 ? "lært: \(bins)/11 punkter (\(m.chargeSessions ?? 0) ladninger)" : "endnu ikke lært")
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
