//
//  GPSRecorder.swift
//  ID3Maps host app.
//
//  Records how fast you drive (and how much you climb) with the iPhone's GPS, so the Worker
//  can predict each trip from the real speed profile instead of coarse 2-minute odometer
//  averages (the odometer only reports whole km).
//
//  Privacy: positions NEVER leave the phone. Per driving segment only these aggregates are
//  uploaded: start/end time, seconds and km per 20 km/h speed bin (Maps' bins), and metres
//  climbed / descended.
//
//  Battery: when not driving only "significant location changes" are monitored (cell/Wi-Fi
//  based, near zero cost). A significant change wakes the app; precise GPS then runs while
//  moving and is switched off again after 10 minutes standing still.
//

import Foundation
import CoreLocation

/// The aggregates of one driving segment (what is uploaded).
struct GPSSegment: Codable, Sendable {
    var start: Date
    var end: Date
    var binSec = [Double](repeating: 0, count: 10)
    var binKm = [Double](repeating: 0, count: 10)
    var gainM = 0.0
    var lossM = 0.0

    var km: Double { binKm.reduce(0, +) }
}

/// A location fix reduced to plain values (crosses from the delegate into the main actor).
private struct Fix: Sendable {
    let t: Date
    let speed: Double      // m/s, < 0 when invalid
    let speedAcc: Double   // m/s, < 0 when invalid
    let alt: Double
    let vAcc: Double       // < 0 when invalid
    let lat: Double
    let lon: Double
    let hAcc: Double       // < 0 when invalid
}

@MainActor
final class GPSRecorder: NSObject, CLLocationManagerDelegate {
    static let shared = GPSRecorder()

    private static let enabledKey = "gpsEnabled"
    private static let queueKey = "gpsUploadQueue"
    private static let movingMps = 2.5            // ~9 km/h counts as driving
    private static let idleEndSec = 10.0 * 60     // segment ends after 10 min standing still

    private let manager = CLLocationManager()
    private var precise = false
    /// CarPlay drive in progress (Start kørsel): keep precise GPS on through stops, so the OBD
    /// dongle (which only reads the car while it moves) sees the car move again at once.
    private var driveSince: Date?
    private var seg: GPSSegment?
    private var lastFix: Date?
    private var lastMoving: Date?
    private var idleTail = 0.0                     // seconds standing still at the end of the segment
    private var refAlt: Double?
    /// Where the current segment started and the last good position, for the phone's own drive
    /// log (Kørebog). Kept on the phone only; never part of the upload.
    private var segFrom: LogPlace?
    private var lastPlace: LogPlace?
    /// Last good position before the segment started (the parking spot you drove off from).
    private var parkedPlace: LogPlace?

    private(set) var lastUploadNote = ""

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    var authorizationText: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "altid ✓"
        case .authorizedWhenInUse: return "kun når appen er åben (vælg Altid i Indstillinger)"
        case .denied: return "afvist (slå til i Indstillinger)"
        case .restricted: return "begrænset"
        case .notDetermined: return "ikke spurgt endnu"
        @unknown default: return "ukendt"
        }
    }

    var isRecording: Bool { seg != nil }

    /// Called at every app launch (also when iOS relaunches the app in the background for a
    /// significant location change).
    func start() {
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.startMonitoringSignificantLocationChanges()
            Task { await flushQueue() }
        default:
            break
        }
    }

    /// CarPlay connected (Shortcuts): switch precise GPS on now instead of waiting for movement.
    func beginDriveNow() {
        guard enabled else { return }
        start()
        precise = true
        lastMoving = Date()
        driveSince = Date()
        manager.startUpdatingLocation()
    }

    /// CarPlay disconnected: close the segment now, upload it, and let GPS sleep.
    func endDriveNow() async {
        driveSince = nil
        finishSegment()
        manager.stopUpdatingLocation()
        precise = false
        await flushQueue()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        precise = false
        finishSegment()
    }

    // MARK: CLLocationManagerDelegate (called off the main actor)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            OBDManager.shared.noteGPS(speed: l.speed, valid: l.speed >= 0 && (l.speedAccuracy < 0 || l.speedAccuracy < 3), at: l.timestamp)
        }
        let fixes = locations.map {
            Fix(t: $0.timestamp, speed: $0.speed, speedAcc: $0.speedAccuracy, alt: $0.altitude, vAcc: $0.verticalAccuracy,
                lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, hAcc: $0.horizontalAccuracy)
        }
        Task { @MainActor in self.handle(fixes) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            SharedLog.shared.log("GPS authorization: \(self.authorizationText)", category: "gps")
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let text = "\(error)"
        Task { @MainActor in SharedLog.shared.log("GPS error: \(text)", category: "gps") }
    }

    // MARK: Recording

    private func handle(_ fixes: [Fix]) {
        guard enabled else { return }
        if !precise {
            // A significant change (or any fix) while not recording: switch precise GPS on and see.
            precise = true
            lastMoving = Date()
            manager.startUpdatingLocation()
        }
        for f in fixes { add(f) }
        // Not driving any more (or never started): end the segment and let GPS sleep.
        if let lm = lastMoving, Date().timeIntervalSince(lm) > Self.idleEndSec {
            finishSegment()
            // During a CarPlay drive GPS stays on through stops of up to 30 min (charging, queues);
            // longer means the end event was probably missed: sleep until a significant change.
            if driveSince != nil, Date().timeIntervalSince(lm) < 30 * 60 { return }
            driveSince = nil
            manager.stopUpdatingLocation()
            precise = false
        }
    }

    private func add(_ f: Fix) {
        let validSpeed = f.speed >= 0 && (f.speedAcc < 0 || f.speedAcc < 3)
        let moving = validSpeed && f.speed >= Self.movingMps
        if f.hAcc >= 0 && f.hAcc < 100 {
            let p = LogPlace(lat: f.lat, lon: f.lon)
            lastPlace = p
            if seg == nil { parkedPlace = p }
        }
        if moving {
            lastMoving = f.t
            if seg == nil {
                seg = GPSSegment(start: f.t, end: f.t)
                segFrom = parkedPlace ?? lastPlace
                idleTail = 0
                refAlt = nil
                SharedLog.shared.log("GPS: driving started", category: "gps")
            }
        }
        guard var s = seg else { lastFix = f.t; return }
        if let prev = lastFix {
            let dt = f.t.timeIntervalSince(prev)
            if dt > 0 && dt < 30 {
                let v = validSpeed ? f.speed : 0
                let bin = min(9, Int(v * 3.6 / 20))
                s.binSec[bin] += dt
                s.binKm[bin] += v * dt / 1000
                idleTail = moving ? 0 : idleTail + dt
            }
        }
        // Elevation with 5 m hysteresis: GPS altitude jitters by several metres.
        if f.vAcc > 0 && f.vAcc < 10 {
            if let ref = refAlt {
                let d = f.alt - ref
                if d >= 5 { s.gainM += d; refAlt = f.alt } else if d <= -5 { s.lossM -= d; refAlt = f.alt }
            } else {
                refAlt = f.alt
            }
        }
        s.end = f.t
        seg = s
        lastFix = f.t
    }

    private func finishSegment() {
        guard var s = seg else { return }
        seg = nil
        s.binSec[0] = max(0, s.binSec[0] - idleTail) // the final standstill is parking, not driving
        if let lm = lastMoving, lm < s.end { s.end = lm }
        idleTail = 0
        guard s.km >= 1 else { return }
        DriveLog.shared.addDrive(start: s.start, end: s.end, km: s.km, from: segFrom, to: lastPlace)
        segFrom = nil
        SharedLog.shared.log(String(format: "GPS: segment %.1f km, +%.0f/-%.0f m", s.km, s.gainM, s.lossM), category: "gps")
        var queue = Self.loadQueue()
        queue.append(s)
        Self.saveQueue(Array(queue.suffix(50)))
        Task { await flushQueue() }
    }

    // MARK: Upload (aggregates only)

    private static func loadQueue() -> [GPSSegment] {
        guard let d = UserDefaults.standard.data(forKey: queueKey) else { return [] }
        return (try? JSONDecoder().decode([GPSSegment].self, from: d)) ?? []
    }

    private static func saveQueue(_ q: [GPSSegment]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(q), forKey: queueKey)
    }

    func flushQueue() async {
        let queue = Self.loadQueue()
        guard !queue.isEmpty, let token = SharedStore.string(.statusToken), !token.isEmpty else { return }
        let body: [String: Any] = ["segments": queue.map { s in
            [
                "start": s.start.timeIntervalSince1970 * 1000, "end": s.end.timeIntervalSince1970 * 1000,
                "binSec": s.binSec, "binKm": s.binKm, "gainM": s.gainM, "lossM": s.lossM,
            ] as [String: Any]
        }]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: URL(string: "https://id3.78fvr47qyz.workers.dev/gps")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                Self.saveQueue([])
                lastUploadNote = "\(queue.count) segment(er) sendt \(Date().formatted(date: .omitted, time: .shortened))"
                SharedLog.shared.log("GPS: uploaded \(queue.count) segment(s)", category: "gps")
            }
        } catch {
            SharedLog.shared.log("GPS upload failed (kept for later): \(error)", category: "gps")
        }
    }
}
