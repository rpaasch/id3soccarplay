//
//  PowerLevelHandler.swift
//  ID3Maps Intents extension.
//
//  Answers INGetCarPowerLevelStatusIntent — the battery/charging status Maps
//  uses for EV routing. The state comes from the Worker (Smartcar); if the
//  Worker is unreachable the last cached real measurement is used. If there is
//  no real data at all we answer `.failure` rather than invent a number.
//
//  While Maps is subscribed (navigation), ONE background loop re-reads the state
//  every minute and pushes an update only when it matters: SoC moved by at least
//  one percentage point, charging toggled, the dynamic numbers moved ~5 %, or a
//  newer measurement arrived. Maps recalculates the route on every push, so we
//  keep pushes rare.
//
//  Maps creates a NEW handler object for every intent, so a stop request often
//  arrives on a different instance than the start. The loop therefore lives in a
//  process-wide coordinator, not in the handler (an earlier per-instance version
//  leaked loops and pushed every update twice).
//

import Intents

/// Lets a non-Sendable ObjC object cross into a Task. Used once, for the observer.
private struct UnsafeBox<T>: @unchecked Sendable { let value: T }

final class PowerLevelHandler: NSObject, INGetCarPowerLevelStatusIntentHandling, @unchecked Sendable {

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
        let adjusted = profile.adjusted(with: s.model)
        SharedLog.shared.log(
            "INGetCarPowerLevelStatus[handle] -> SoC \(Int((s.stateOfCharge * 100).rounded()))% "
                + "(\(current.origin.rawValue), measured \(Int(Date().timeIntervalSince(s.measuredAt) / 60)) min ago, "
                + "charging \(s.isCharging)); model: \(adjusted.note)",
            category: "power"
        )
        return MapsPowerResponse.make(state: s, profile: adjusted.profile)
    }

    // MARK: Live updates during navigation

    func startSendingUpdates(
        for intent: INGetCarPowerLevelStatusIntent,
        to observer: INGetCarPowerLevelStatusIntentResponseObserver
    ) {
        SharedLog.shared.log("startSendingUpdates (Maps subscribed)", category: "power")
        UpdateCoordinator.shared.start(observer)
    }

    func stopSendingUpdates(for intent: INGetCarPowerLevelStatusIntent) {
        SharedLog.shared.log("stopSendingUpdates", category: "power")
        UpdateCoordinator.shared.stop()
    }

    // MARK: Push rule

    /// Push the first state, then only on >= 1 percentage point, a charging
    /// change, a ~5 % move in the dynamic numbers, or a newer real measurement.
    fileprivate static func shouldPush(new: VehicleState, last: VehicleState?) -> Bool {
        guard let last else { return true }
        if abs(new.stateOfCharge - last.stateOfCharge) >= 0.01 { return true }
        if new.isCharging != last.isCharging { return true }
        if modelChanged(new.model, last.model) { return true }
        return new.measuredAt > last.measuredAt
    }

    /// True when the dynamic numbers moved enough to matter (>= ~5 %), so Maps
    /// is not made to re-route over noise.
    private static func modelChanged(_ a: ModelHints?, _ b: ModelHints?) -> Bool {
        func differs(_ x: Double?, _ y: Double?) -> Bool {
            guard let x, let y else { return (x == nil) != (y == nil) }
            return abs(x - y) / max(abs(y), 0.0001) >= 0.05
        }
        return differs(a?.consumptionKwhPer100, b?.consumptionKwhPer100)
            || differs(a?.chargePowerScale, b?.chargePowerScale)
            || differs(a?.capacityKwhNet, b?.capacityKwhNet)
    }
}

/// The single live-update loop of this extension process.
///
/// `start` replaces any previous subscription (a new Maps subscription supersedes the
/// old one); `stop` ends it. A generation counter makes a superseded loop exit on its
/// own, so there can never be two loops pushing at once.
private final class UpdateCoordinator: @unchecked Sendable {
    static let shared = UpdateCoordinator()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var observer: UnsafeBox<INGetCarPowerLevelStatusIntentResponseObserver>?
    private var generation = 0

    func start(_ observer: INGetCarPowerLevelStatusIntentResponseObserver) {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        let mine = generation
        self.observer = UnsafeBox(value: observer)
        task?.cancel()
        task = Task { await self.run(generation: mine) }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        task?.cancel()
        task = nil
        observer = nil
    }

    private func currentObserver(for generation: Int) -> UnsafeBox<INGetCarPowerLevelStatusIntentResponseObserver>? {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation ? observer : nil
    }

    private func run(generation: Int) async {
        var lastPushed: VehicleState?
        while !Task.isCancelled {
            guard currentObserver(for: generation) != nil else { return } // superseded or stopped
            if let profile = try? VehicleProfile.load(),
               let current = await StateProvider.current(timeout: 6, background: true) {
                let s = current.state
                if PowerLevelHandler.shouldPush(new: s, last: lastPushed),
                   let target = currentObserver(for: generation) {
                    let adjusted = profile.adjusted(with: s.model)
                    target.value.didUpdate(getCarPowerLevelStatus: MapsPowerResponse.make(state: s, profile: adjusted.profile))
                    lastPushed = s
                    SharedLog.shared.log(
                        "push -> SoC \(Int((s.stateOfCharge * 100).rounded()))% (\(current.origin.rawValue)); model: \(adjusted.note)",
                        category: "power"
                    )
                }
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
