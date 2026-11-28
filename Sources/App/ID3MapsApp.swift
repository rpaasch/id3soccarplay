//
//  ID3MapsApp.swift
//  ID3Maps host app.
//
//  M0 host app: shows the hard-coded status, lets us donate a test interaction
//  to help SiriKit register the car, and shows/exports the shared log.
//

import SwiftUI

@main
struct ID3MapsApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Figtree.styleBars()
        NetworkLog.shared.start()
        CarPlayRoute.shared.start()
        SharedLog.shared.log("App launched (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))", category: "app")
        // Also runs when iOS relaunches the app in the background for a significant location change.
        GPSRecorder.shared.start()
        OBDManager.shared.start() // connects only during an active drive (CarPlay)
        Task { await DriveEvents.flush() } // events that could not be sent earlier
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .font(.fig(.body))
        }
        .onChange(of: scenePhase) { _, phase in
            let name = switch phase { case .active: "active"; case .inactive: "inactive"; case .background: "background"; @unknown default: "?" }
            SharedLog.shared.log("app \(name)", category: "app")
            if phase == .background { SharedLog.shared.flush() }
        }
    }
}
