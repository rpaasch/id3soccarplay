//
//  CarPlayRoute.swift
//  ID3Maps host app.
//
//  Is CarPlay connected right now? While it is, the phone's audio route has an output of type
//  "carAudio". The app only reads the route; it never activates or changes the audio session,
//  so CarPlay audio is not affected.
//
//  Stage 1 (now): logging only, to see whether iOS reports the route reliably while the app runs
//  in the background. If it does, the OBD dongle will require it before every request to the car.
//

import AVFAudio
import Foundation

final class CarPlayRoute: @unchecked Sendable {
    static let shared = CarPlayRoute()

    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var lastLogged: Bool?

    /// True when an output of the current audio route is CarPlay.
    var connectedNow: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
    }

    /// Short description of the current route, e.g. "carAudio:CarPlay".
    var routeText: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.isEmpty ? "none" : outs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
    }

    /// Logs every route change (with the reason), so the log shows when CarPlay comes and goes.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self?.logState(reason: "route change (reason \(raw))", force: true)
        }
        logState(reason: "app start", force: true)
    }

    /// Logs the state; unless forced only when it changed since the last log line.
    func logState(reason: String, force: Bool = false) {
        let now = connectedNow
        lock.lock()
        let changed = lastLogged != now
        lastLogged = now
        lock.unlock()
        guard force || changed else { return }
        SharedLog.shared.log("CarPlay route: \(now ? "CONNECTED" : "not connected") [\(routeText)] – \(reason)", category: "carplay")
    }
}
