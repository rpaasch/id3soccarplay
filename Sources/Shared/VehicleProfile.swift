//
//  VehicleProfile.swift
//  ID3Maps — shared between app and Intents extension.
//
//  Loads `id3.json` from the target bundle and exposes the values Apple Maps
//  needs: the masquerade make/model (Porsche/Taycan, see docs/M-1 §8), the
//  charging connectors, and the two formula dictionaries.
//
//  The dictionaries deliberately keep Porsche's `model_id`s (12582912 /
//  12582916) because the VirtualGarage Siri allowlist checks the model id, not
//  only the bundle id. The *values* inside them are ID.3 estimates.
//

import Foundation

/// Decoded representation of `id3.json`.
struct VehicleProfile: Sendable, Codable {
    struct Vehicle: Sendable, Codable {
        let realMake: String
        let realModel: String
        let year: Int
        let mapsMake: String
        let mapsModel: String
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case realMake = "real_make"
            case realModel = "real_model"
            case year
            case mapsMake = "maps_make"
            case mapsModel = "maps_model"
            case displayName = "display_name"
        }
    }

    struct Battery: Sendable, Codable {
        let usableCapacityWh: Double
        enum CodingKeys: String, CodingKey { case usableCapacityWh = "usable_capacity_wh" }
    }

    struct Range: Sendable, Codable {
        let wltpKm: Double
        enum CodingKeys: String, CodingKey { case wltpKm = "wltp_km" }
    }

    struct Connector: Sendable, Codable {
        let type: String          // "mennekes" | "ccs2"
        let maxPowerKw: Double
        enum CodingKeys: String, CodingKey {
            case type
            case maxPowerKw = "max_power_kw"
        }
    }

    /// A `{ model_id, vehicle_parameters }` contract. `vehicleParameters` is kept
    /// as raw JSON so it can be handed to Intents verbatim without lossy typing.
    struct Contract: Sendable, Codable {
        let modelId: Int
        let vehicleParameters: JSONObject
        enum CodingKeys: String, CodingKey {
            case modelId = "model_id"
            case vehicleParameters = "vehicle_parameters"
        }
    }

    let vehicle: Vehicle
    let battery: Battery
    let range: Range
    let connectors: [Connector]
    let consumptionContract: Contract
    let chargingContract: Contract

    enum CodingKeys: String, CodingKey {
        case vehicle
        case battery
        case range
        case connectors
        case consumptionContract = "consumption_contract"
        case chargingContract = "charging_contract"
    }
}

extension VehicleProfile {
    enum LoadError: Error { case missingResource }

    /// Loads `id3.json` from the given bundle (the app or extension bundle).
    static func load(from bundle: Bundle = .main) throws -> VehicleProfile {
        guard let url = bundle.url(forResource: "id3", withExtension: "json") else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VehicleProfile.self, from: data)
    }

    /// Arguments for `INGetCarPowerLevelStatusIntentResponse.consumptionFormulaArguments`.
    func consumptionFormulaArguments() -> [String: Any] {
        ["model_id": consumptionContract.modelId,
         "vehicle_parameters": consumptionContract.vehicleParameters.value]
    }

    /// Arguments for `INGetCarPowerLevelStatusIntentResponse.chargingFormulaArguments`.
    func chargingFormulaArguments() -> [String: Any] {
        ["model_id": chargingContract.modelId,
         "vehicle_parameters": chargingContract.vehicleParameters.value]
    }
}
