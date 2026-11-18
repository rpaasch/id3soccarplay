//
//  PowerLevelHandler.swift
//  ID3Maps Intents extension.
//
//  Answers INGetCarPowerLevelStatusIntent — the battery/charging status Maps
//  uses for EV routing. The state comes from the Worker (Smartcar); if the
//  Worker is unreachable the last cached real measurement is used. If there is
//  no real data at all we answer `.failure` rather than invent a number.
//
//  While Maps is subscribed (navigation), a background task re-reads the state
//  every minute and pushes an update only when it matters: SoC moved by at least
//  one percentage point, charging toggled, or a newer measurement arrived. (Maps
//  recalculates the route on every push, so we keep pushes rare.)
//

import Intents

/// Lets a non-Sendable ObjC object cross into a Task. Used once, for the observer.
private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

final class PowerLevelHandler: NSObject, INGetCarPowerLevelStatusIntentHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var updateTask: Task<Void, Never>?

    // MARK: One-shot query

    func handle(intent: INGetCarPowerLevelStatusIntent) async -> INGetCarPowerLevelStatusIntentResponse {
        guard let profile = try? VehicleProfile.load() else {
            SharedLog.shared.log("power status failed: id3.json missing", category: "power")
            return INGetCarPowerLevelStatusIntentResponse(code: .failure, userActivity: nil)
        }
        guard let current = await StateProvider.current() else {
            SharedLog.shared.log("INGetCarPowerLevelStatus[handle] -> FAILURE (no live or cached data)", category: "power")
            return INGetCarPowerLevelStatusIntentResponse(code: .failure, userActivity: nil)
        }
        let s = current.state
        SharedLog.shared.log(
            "INGetCarPowerLevelStatus[handle] -> SoC \(Int((s.stateOfCharge * 100).rounded()))% "
                + "(\(current.origin.rawValue), measured \(Int(Date().timeIntervalSince(s.measuredAt) / 60)) min ago, "
                + "charging \(s.isCharging))",
            category: "power"
        )
        return MapsPowerResponse.make(state: s, profile: profile)
    }

    // MARK: Live updates during navigation

    func startSendingUpdates(
        for intent: INGetCarPowerLevelStatusIntent,
        to observer: INGetCarPowerLevelStatusIntentResponseObserver
    ) {
        SharedLog.shared.log("startSendingUpdates (Maps subscribed)", category: "power")
        let box = UnsafeBox(value: observer)

        let task = Task { [self] in
            var lastPushed: VehicleState?
            while !Task.isCancelled {
                if let profile = try? VehicleProfile.load(), let current = await StateProvider.current() {
                    let s = current.state
                    if Self.shouldPush(new: s, last: lastPushed) {
                        box.value.didUpdate(getCarPowerLevelStatus: MapsPowerResponse.make(state: s, profile: profile))
                        lastPushed = s
                        SharedLog.shared.log(
                            "push -> SoC \(Int((s.stateOfCharge * 100).rounded()))% (\(current.origin.rawValue))",
                            category: "power"
                        )
                    }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        lock.lock()
        updateTask?.cancel()
        updateTask = task
        lock.unlock()
    }

    func stopSendingUpdates(for intent: INGetCarPowerLevelStatusIntent) {
        SharedLog.shared.log("stopSendingUpdates", category: "power")
        lock.lock()
        updateTask?.cancel()
        updateTask = nil
        lock.unlock()
    }

    // MARK: Push rule

    /// Push the first state, then only on >= 1 percentage point, a charging
    /// change, or a newer real measurement.
    private static func shouldPush(new: VehicleState, last: VehicleState?) -> Bool {
        guard let last else { return true }
        if abs(new.stateOfCharge - last.stateOfCharge) >= 0.01 { return true }
        if new.isCharging != last.isCharging { return true }
        return new.measuredAt > last.measuredAt
    }
}
