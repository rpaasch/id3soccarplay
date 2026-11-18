//
//  ContentView.swift
//  ID3Maps host app (M0).
//

import SwiftUI
import UIKit
import Intents

struct ContentView: View {
    @State private var profile: VehicleProfile?
    @State private var loadError: String?
    @State private var entries: [LogEntry] = []
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var siriStatus = "unknown"

    private let state = VehicleState.hardcodedM0()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                actionSection
                logSection
            }
            .navigationTitle("ID.3 Maps (M0)")
            .onAppear(perform: reload)
            .refreshable { reload() }
            .sheet(isPresented: $showShare) {
                if let url = exportURL { ShareSheet(items: [url]) }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section("Status (hardkodet)") {
            if let p = profile {
                row("Bil (rigtig)", "\(p.vehicle.realMake) \(p.vehicle.realModel) \(p.vehicle.year)")
                row("Maskering i Maps", "\(p.vehicle.mapsMake) \(p.vehicle.mapsModel)")
                row("SoC", "\(Int(state.stateOfCharge * 100)) %")
                row("Rækkevidde", state.rangeKm.map { "\(Int($0)) km" } ?? "–")
                row("Kapacitet", "\(Int(p.battery.usableCapacityWh / 1000)) kWh")
                row("consumption model_id", "\(p.consumptionContract.modelId)")
                row("charging model_id", "\(p.chargingContract.modelId)")
            } else if let e = loadError {
                Text("Kunne ikke læse id3.json: \(e)").foregroundStyle(.red)
            } else {
                ProgressView()
            }
            row("Siri-tilladelse", siriStatus)
        }
    }

    private var actionSection: some View {
        Section("Handlinger") {
            Button("Anmod om Siri-tilladelse") { requestSiri() }
            Button("Send testinteraktion til Maps/Siri") { donateTestInteraction() }
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

    // MARK: Actions

    private func reload() {
        do { profile = try VehicleProfile.load(); loadError = nil }
        catch { loadError = "\(error)" }
        entries = SharedLog.shared.entries()
        siriStatus = siriStatusText(INPreferences.siriAuthorizationStatus())
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
