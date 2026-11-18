//
//  CarListHandler.swift
//  ID3Maps Intents extension.
//
//  Answers INListCarsIntent — the call Maps makes to discover the user's
//  vehicle(s). Returns a single masqueraded car built from id3.json.
//

import Intents

final class CarListHandler: NSObject, INListCarsIntentHandling {
    func handle(intent: INListCarsIntent, completion: @escaping (INListCarsIntentResponse) -> Void) {
        do {
            let profile = try VehicleProfile.load()
            let car = MapsCar.make(profile: profile)
            let response = INListCarsIntentResponse(code: .success, userActivity: nil)
            response.cars = [car]
            SharedLog.shared.log(
                "INListCarsIntent -> 1 car (make=\(profile.vehicle.mapsMake) model=\(profile.vehicle.mapsModel))",
                category: "listCars"
            )
            completion(response)
        } catch {
            SharedLog.shared.log("INListCarsIntent failed: \(error)", category: "listCars")
            completion(INListCarsIntentResponse(code: .failure, userActivity: nil))
        }
    }
}
