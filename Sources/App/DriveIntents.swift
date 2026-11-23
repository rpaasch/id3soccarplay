//
//  DriveIntents.swift
//  ID3Maps host app.
//
//  "Start kørsel" / "Slut kørsel" for Shortcuts automations ("When CarPlay connects/disconnects").
//  Apps may not observe Wi-Fi/Bluetooth connections themselves; Shortcuts may, and it can run these
//  in the background without asking. They give exact trip boundaries, which VW's odometer (only
//  every ~20 min) cannot:
//   * GPS recording starts/stops immediately,
//   * the OBD dongle may talk only between these two events (never to a parked or locked car),
//   * the Worker is told, so the trip log starts/ends at the right moment.
//

import AppIntents
import Foundation

struct StartDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Start kørsel"
    static let description = IntentDescription("Starter GPS-måling og OBD og fortæller Workeren, at en tur begynder. Brug den i en automatisering: Når CarPlay forbinder.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedLog.shared.log("Drive start (Shortcuts/CarPlay)", category: "drive")
        GPSRecorder.shared.beginDriveNow()
        OBDManager.shared.beginDrive()
        await DriveEvents.send("start")
        return .result()
    }
}

struct EndDriveIntent: AppIntent {
    static let title: LocalizedStringResource = "Slut kørsel"
    static let description = IntentDescription("Afslutter GPS-målingen og fortæller Workeren, at turen er slut. Brug den i en automatisering: Når CarPlay afbryder.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        SharedLog.shared.log("Drive end (Shortcuts/CarPlay)", category: "drive")
        OBDManager.shared.endDrive() // first: stop talking to the car before it can be locked
        await DriveEvents.send("end")
        await GPSRecorder.shared.endDriveNow()
        return .result()
    }
}

/// "Hey Siri, fejl i ID3Maps": marks the moment Maps reported a lost connection, so it can be
/// found in the log afterwards. Also checks right away whether the Worker answers and how fast.
struct MarkIssueIntent: AppIntent {
    static let title: LocalizedStringResource = "Markér fejl"
    static let description = IntentDescription("Sætter et mærke i loggen, når Maps siger, at forbindelsen er mistet, og tjekker forbindelsen.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let t0 = Date()
        var result: String
        do {
            let s = try await StatusClient.fetch(timeout: 8)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            result = "Worker OK på \(ms) ms, SoC \(Int((s.stateOfCharge * 100).rounded())) %, bilens tal \(Int(Date().timeIntervalSince(s.measuredAt) / 60)) min gamle"
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            result = "Worker svarede IKKE (\((error as? URLError)?.code.rawValue ?? 0), \(ms) ms)"
        }
        SharedLog.shared.log("USER MARK: Maps mistede forbindelsen. \(result)", category: "mark")
        return .result(dialog: "Markeret. \(result.hasPrefix("Worker OK") ? "Forbindelsen til Workeren virker." : "Workeren svarede ikke.")")
    }
}

struct ID3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartDriveIntent(), phrases: ["Start kørsel i \(.applicationName)"],
                    shortTitle: "Start kørsel", systemImageName: "car.fill")
        AppShortcut(intent: EndDriveIntent(), phrases: ["Slut kørsel i \(.applicationName)"],
                    shortTitle: "Slut kørsel", systemImageName: "parkingsign")
        AppShortcut(intent: MarkIssueIntent(), phrases: ["Fejl i \(.applicationName)", "Markér fejl i \(.applicationName)"],
                    shortTitle: "Markér fejl", systemImageName: "exclamationmark.bubble")
    }
}

/// Start/end events for the Worker. Queued on the phone and retried, so a moment without
/// network (22 Nov: "drive end not sent") no longer loses a trip boundary. Each event keeps the
/// time it happened; the Worker accepts times up to an hour old.
enum DriveEvents {
    private struct Pending: Codable { let event: String; let at: Double }
    private static let queueKey = "driveEventQueue"

    private static func load() -> [Pending] {
        guard let d = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([Pending].self, from: d)) ?? []
    }

    private static func save(_ q: [Pending]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(q), forKey: queueKey)
    }

    static func send(_ event: String) async {
        var q = load()
        q.append(Pending(event: event, at: Date().timeIntervalSince1970 * 1000))
        save(Array(q.suffix(20)))
        await flush()
    }

    /// Sends queued events in order; stops at the first failure and keeps the rest for later.
    static func flush() async {
        guard let token = SharedStore.string(.statusToken), !token.isEmpty else { return }
        var q = load()
        while let first = q.first {
            if Date().timeIntervalSince1970 * 1000 - first.at > 55 * 60 * 1000 {
                SharedLog.shared.log("drive \(first.event) dropped (older than 55 min)", category: "drive")
                q.removeFirst()
                continue
            }
            var request = URLRequest(url: URL(string: "https://id3.78fvr47qyz.workers.dev/drive")!, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["event": first.event, "at": first.at])
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { break }
                q.removeFirst()
            } catch {
                SharedLog.shared.log("drive \(first.event) not sent yet (kept for later): \((error as? URLError)?.code.rawValue ?? 0)", category: "drive")
                break
            }
        }
        save(q)
    }
}
