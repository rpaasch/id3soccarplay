//
//  TripsClient.swift
//  ID3Maps host app.
//
//  Reads the trip log from the Worker (`GET /trips`): every drive with the energy it really
//  used and what the physics model (the numbers Maps gets) predicted for the same speeds and
//  temperature. The ratio between the two is the calibration Maps uses.
//

import Foundation

struct Trip: Decodable, Identifiable, Sendable {
    let start: Double
    let end: Double
    let km: Double
    let socFrom: Double
    let socTo: Double
    let kwh: Double
    let kwhPer100: Double
    let tempC: Double?
    let avgKmh: Double?
    let predictedKwh: Double
    let predictedPer100: Double
    let ratio: Double
    let cold: Bool?

    var id: Double { start }
    var startDate: Date { Date(timeIntervalSince1970: start / 1000) }
}

struct TripCalibration: Codable, Sendable {
    let factor: Double
    let km: Double
    let n: Int
    /// "temperature" (trips within +-4 °C of now) or "all".
    let scope: String
}

struct TripsResponse: Decodable, Sendable {
    let trips: [Trip]
    let calibration: TripCalibration?
}

enum TripsClient {
    static let url = URL(string: "https://id3.78fvr47qyz.workers.dev/trips")!

    static func fetch() async throws -> TripsResponse {
        guard let token = SharedStore.string(.statusToken), !token.isEmpty else { throw StatusError.noToken }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw StatusError.http(code) }
        return try JSONDecoder().decode(TripsResponse.self, from: data)
    }
}
