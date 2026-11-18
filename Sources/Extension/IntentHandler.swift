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
    override func handler(for intent: INIntent) -> Any? {
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
