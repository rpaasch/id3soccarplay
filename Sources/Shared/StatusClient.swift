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

    /// Fetches the current state from the Worker. Short timeout: Maps is waiting.
    static func fetch(timeout: TimeInterval = 3) async throws -> VehicleState {
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
            chargeKind: status.charging == true ? status.chargeKind : nil
        )
    }
}

enum StateProvider {
    enum Origin: String { case live, cache }

    /// Best available state: live from the Worker, else the last cached one, else nil.
    static func current(timeout: TimeInterval = 2.5) async -> (state: VehicleState, origin: Origin)? {
        do {
            let state = try await StatusClient.fetch(timeout: timeout)
            SharedStore.setCodable(state, for: .lastState)
            return (state, .live)
        } catch {
            SharedLog.shared.log("status fetch failed: \(error)", category: "status")
            if let cached: VehicleState = SharedStore.codable(.lastState) {
                return (cached, .cache)
            }
            return nil
        }
    }
}
