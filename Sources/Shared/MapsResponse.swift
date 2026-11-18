//
//  MapsResponse.swift
//  ID3Maps — shared between app and Intents extension.
//
//  Builds the `INCar` and the `INGetCarPowerLevelStatusIntentResponse` from a
//  `VehicleProfile` + `VehicleState`. Kept in one place so the extension and the
//  app's "send test update" button produce identical objects.
//

import Foundation
import Intents

enum MapsCar {
    /// Stable identifier so Maps remembers the vehicle across launches.
    /// (Apple's docs warn against using the VIN; a fixed UUID is fine.)
    static let identifier = UUID(uuidString: "1D300000-0000-4000-A000-000000000003")!

    static func connectorType(_ raw: String) -> INCar.ChargingConnectorType {
        // The ID.3 only has Type 2 (AC) + CCS2 (DC). Keep the mapping to the two
        // connector constants we actually use; anything else falls back to CCS2.
        switch raw.lowercased() {
        case "mennekes", "type2": return .mennekes
        default: return .ccs2
        }
    }

    /// Builds the `INCar` Maps lists under Vehicles.
    ///
    /// NOTE: `make`/`model` are the *masquerade* values (Porsche/Taycan) because
    /// the VirtualGarage Siri allowlist matches make/model + bundle id. See
    /// docs/M-1 §8. The real VW ID.3 parameters are carried in the formula
    /// dictionaries on the power-level response.
    static func make(profile: VehicleProfile) -> INCar {
        let connectors = profile.connectors.map { connectorType($0.type) }

        let car = INCar(
            carIdentifier: identifier.uuidString,
            displayName: profile.vehicle.displayName,
            year: String(profile.vehicle.year),
            make: profile.vehicle.mapsMake,
            model: profile.vehicle.mapsModel,
            color: nil,
            headUnit: nil,                       // set once we know the ID.3 BT id
            supportedChargingConnectors: connectors
        )

        for connector in profile.connectors {
            car.setMaximumPower(
                Measurement(value: connector.maxPowerKw, unit: .kilowatts),
                for: connectorType(connector.type)
            )
        }
        return car
    }
}

enum MapsPowerResponse {
    /// Builds the response Maps reads for routing.
    static func make(
        state: VehicleState,
        profile: VehicleProfile,
        carId: UUID = MapsCar.identifier
    ) -> INGetCarPowerLevelStatusIntentResponse {
        let response = INGetCarPowerLevelStatusIntentResponse(code: .success, userActivity: nil)

        response.carIdentifier = carId.uuidString
        response.chargePercentRemaining = Float(state.stateOfCharge)

        // Timestamp of the last real measurement.
        response.dateOfLastStateUpdate = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: state.measuredAt
        )

        // The two undocumented dictionaries that make routing work.
        response.consumptionFormulaArguments = profile.consumptionFormulaArguments()
        response.chargingFormulaArguments = profile.chargingFormulaArguments()

        // Battery capacity. Keep units consistent: kilowattHours throughout.
        let capacityKWh = profile.battery.usableCapacityWh / 1000.0
        response.minimumBatteryCapacity = Measurement(value: 0, unit: .kilowattHours)
        response.maximumBatteryCapacity = Measurement(value: capacityKWh, unit: .kilowattHours)
        response.currentBatteryCapacity = Measurement(value: capacityKWh * state.stateOfCharge, unit: .kilowattHours)

        // Range.
        let maxRange = profile.range.wltpKm
        response.maximumDistance = Measurement(value: maxRange, unit: .kilometers)
        response.maximumDistanceElectric = Measurement(value: maxRange, unit: .kilometers)
        if let km = state.rangeKm {
            response.distanceRemaining = Measurement(value: km, unit: .kilometers)
            response.distanceRemainingElectric = Measurement(value: km, unit: .kilometers)
        }

        // Charging.
        response.charging = state.isCharging
        if state.isCharging {
            response.activeConnector = state.chargeKind == "ac" ? .mennekes : .ccs2
            if let m = state.minutesToFull { response.minutesToFull = m }
        }

        return response
    }
}
