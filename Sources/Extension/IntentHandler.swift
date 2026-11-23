//
//  IntentHandler.swift
//  ID3Maps Intents extension.
//
//  Entry point Maps/SiriKit talks to. Routes the two car intents to their
//  handlers. Every routing decision is written to the shared log so we can see,
//  after a drive, exactly which intents Maps called.
//

import Intents

final class IntentHandler: INExtension {
    /// Runs once per extension process: a new process in the middle of a drive means iOS
    /// restarted the extension, which Maps may show as a lost connection.
    private static let boot: Void = {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        SharedLog.shared.log("extension process started (build \(build), pid \(ProcessInfo.processInfo.processIdentifier))", category: "intent")
        NetworkLog.shared.start()
    }()

    override func handler(for intent: INIntent) -> Any? {
        _ = Self.boot
        SharedLog.shared.log("handler(for: \(type(of: intent)))", category: "intent")

        if intent is INListCarsIntent {
            return CarListHandler()
        }
        if intent is INGetCarPowerLevelStatusIntent {
            return PowerLevelHandler()
        }
        SharedLog.shared.log("No handler for \(type(of: intent))", category: "intent")
        return nil
    }
}
