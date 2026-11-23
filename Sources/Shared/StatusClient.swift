//
//  StatusClient.swift
//  ID3Maps — shared between app and Intents extension.
//
//  Reads the car's battery state from the Cloudflare Worker (`GET /status`),
//  which in turn gets it from Smartcar (webhook push + on-demand polling).
//  Falls back to the last cached state when the Worker is unreachable.
//
//  Honesty rule: `measuredAt` is always the time of the last REAL measurement,
//  so Maps sees how old the number is. Nothing here invents a value.
//

import Foundation

/// JSON returned by the Worker's `/status` endpoint.
private struct RemoteStatus: Decodable {
    let available: Bool
    let soc: Double?
    let rangeKm: Double?
    let charging: Bool?
    /// Milliseconds since 1970 of the last real measurement (OEM time).
    let measuredAt: Double?
    let lastError: String?
    let model: ModelHints?
    /// Minutes to full while charging (Smartcar `TimeToComplete`).
    let minutesToFull: Double?
    /// "ac" or "dc" while charging.
    let chargeKind: String?
    /// Charging power in W (Smartcar), while charging.
    let wattageW: Double?
    let chargeSession: ChargeSessionDTO?
    /// SoC projected to now while driving (VW reports only every few minutes).
    let socEstimate: Double?
}

private struct ChargeSessionDTO: Decodable {
    let samples: [ChargeSample]
}

enum StatusError: Error, CustomStringConvertible {
    case noToken
    case http(Int)
    case unavailable(String?)

    var description: String {
        switch self {
        case .noToken: return "no status token saved in the app"
        case .http(let c): return "worker returned HTTP \(c)"
        case .unavailable(let why): return "no data yet" + (why.map { " (\($0))" } ?? "")
        }
    }
}

enum StatusClient {
    static let url = URL(string: "https://id3.78fvr47qyz.workers.dev/status")!

    /// Fetches the current state from the Worker.
    /// A dropped connection (-1005, common when an extension was just resumed) is retried once;
    /// with `retryOnTimeout` (background updates, nobody waiting) a timeout is retried too.
    static func fetch(timeout: TimeInterval = 3, retryOnTimeout: Bool = false) async throws -> VehicleState {
        do {
            return try await fetchOnce(timeout: timeout)
        } catch let error as URLError where error.code == .networkConnectionLost
                    || (retryOnTimeout && error.code == .timedOut) {
            try await Task.sleep(for: .milliseconds(300))
            return try await fetchOnce(timeout: timeout)
        }
    }

    private static func fetchOnce(timeout: TimeInterval) async throws -> VehicleState {
        guard let token = SharedStore.string(.statusToken), !token.isEmpty else { throw StatusError.noToken }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw StatusError.http(code) }
        let status = try JSONDecoder().decode(RemoteStatus.self, from: data)
        guard status.available, let soc = status.soc, let ms = status.measuredAt else {
            throw StatusError.unavailable(status.lastError)
        }
        return VehicleState(
            stateOfCharge: soc,
            measuredAt: Date(timeIntervalSince1970: ms / 1000),
            isCharging: status.charging ?? false,
            rangeKm: status.rangeKm,
            minutesToFull: (status.charging == true ? status.minutesToFull : nil)
                .flatMap { $0 > 0 ? Int($0.rounded()) : nil },
            model: status.model,
            chargeKind: status.charging == true ? status.chargeKind : nil,
            chargePowerW: status.charging == true ? status.wattageW : nil,
            chargeSamples: status.charging == true ? status.chargeSession?.samples : nil,
            contactAt: Date(),
            socEstimated: nil,
            socEstimate: status.socEstimate,
            workerError: (status.lastError?.isEmpty == false) ? status.lastError : nil
        )
    }
}

/// Process-wide memo of the last live answer. Maps fires bursts of up to ~20 requests within
/// seconds; answering them from a fresh (< 15 s) result avoids a network round trip each time.
private final class RecentState: @unchecked Sendable {
    static let shared = RecentState()
    private let lock = NSLock()
    private var value: (state: VehicleState, at: Date)?
    func get(maxAge: TimeInterval) -> VehicleState? {
        lock.lock(); defer { lock.unlock() }
        guard let v = value, Date().timeIntervalSince(v.at) < maxAge else { return nil }
        return v.state
    }
    func set(_ s: VehicleState) {
        lock.lock(); defer { lock.unlock() }
        value = (s, Date())
    }
}

enum StateProvider {
    enum Origin: String { case live, cache }

    /// Best available state: live from the Worker (or a < 15 s old live answer), else the last
    /// cached one, else nil. Background updates pass a longer timeout and retry on timeout.
    /// Maps gets the projected SoC while driving (VW reports only every few minutes), and never
    /// a value that goes up again while not charging: when VW's next report is a little higher
    /// than the projection, Maps keeps the lower value instead of jumping back (94 -> 95 on 23 Nov).
    private static func forMaps(_ s: VehicleState) -> VehicleState {
        var v = s
        if let r: OBDReading = SharedStore.codable(.obdReading), r.isFreshAndValid, r.at > s.measuredAt {
            // Live from the car via the dongle (seconds old) beats any projection.
            v.stateOfCharge = r.soc
            v.measuredAt = r.at
            v.socEstimated = false
            v.obdLive = true
        } else if let e = s.socEstimate {
            v.stateOfCharge = e
            v.socEstimated = true
        }
        return MapsFloor.shared.apply(v)
    }

    static func current(timeout: TimeInterval = 2.5, background: Bool = false) async -> (state: VehicleState, origin: Origin)? {
        if !background, let recent = RecentState.shared.get(maxAge: 15) { return (forMaps(recent), .live) }
        do {
            let raw = try await StatusClient.fetch(timeout: timeout, retryOnTimeout: background)
            RecentState.shared.set(raw)
            SharedStore.setCodable(raw, for: .lastState)
            return (forMaps(raw), .live)
        } catch {
            SharedLog.shared.log("status fetch failed: \(error)", category: "status")
            if let cached: VehicleState = SharedStore.codable(.lastState) {
                return (cached, .cache)
            }
            return nil
        }
    }
}

/// Remembers the lowest SoC sent to Maps during the current drive.
private final class MapsFloor: @unchecked Sendable {
    static let shared = MapsFloor()
    private let lock = NSLock()
    private var last: (soc: Double, at: Date)?

    func apply(_ s: VehicleState) -> VehicleState {
        lock.lock()
        defer { lock.unlock() }
        // Charging, a real jump (> 2 pp, e.g. after charging) or a pause over 30 min starts afresh.
        if s.isCharging || last == nil || Date().timeIntervalSince(last!.at) > 30 * 60
            || s.stateOfCharge > last!.soc + 0.02 || s.stateOfCharge <= last!.soc {
            last = (s.stateOfCharge, Date())
            return s
        }
        var v = s
        v.stateOfCharge = last!.soc
        last = (last!.soc, Date())
        return v
    }
}
