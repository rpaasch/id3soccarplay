//
//  PowerLevelHandler.swift
//  ID3Maps Intents extension.
//
//  Answers INGetCarPowerLevelStatusIntent — the battery/charging status Maps
//  uses for EV routing. In M0 the state is hard-coded (SoC 60 %). The
//  push-update path (startSendingUpdates) is implemented so we can see whether
//  Maps subscribes during navigation; in M0 it sends one update and holds.
//

import Intents

final class PowerLevelHandler: NSObject, INGetCarPowerLevelStatusIntentHandling {

    // MARK: One-shot query

    func handle(
        intent: INGetCarPowerLevelStatusIntent,
        completion: @escaping (INGetCarPowerLevelStatusIntentResponse) -> Void
    ) {
        completion(makeResponse(tag: "handle"))
    }

    // MARK: Live updates during navigation

    func startSendingUpdates(
        for intent: INGetCarPowerLevelStatusIntent,
        to observer: INGetCarPowerLevelStatusIntentResponseObserver
    ) {
        SharedLog.shared.log("startSendingUpdates (Maps subscribed)", category: "power")
        observer.didUpdate(getCarPowerLevelStatus: makeResponse(tag: "update"))
        // M0: no further pushes. M2 will push on >=1pp change / new measurement.
    }

    func stopSendingUpdates(for intent: INGetCarPowerLevelStatusIntent) {
        SharedLog.shared.log("stopSendingUpdates", category: "power")
    }

    // MARK: Build

    private func makeResponse(tag: String) -> INGetCarPowerLevelStatusIntentResponse {
        do {
            let profile = try VehicleProfile.load()
            let state = VehicleState.hardcodedM0()
            let response = MapsPowerResponse.make(state: state, profile: profile)
            SharedLog.shared.log(
                "INGetCarPowerLevelStatus[\(tag)] -> SoC \(Int(state.stateOfCharge * 100))%, charging \(state.isCharging)",
                category: "power"
            )
            return response
        } catch {
            SharedLog.shared.log("power status failed: \(error)", category: "power")
            return INGetCarPowerLevelStatusIntentResponse(code: .failure, userActivity: nil)
        }
    }
}
