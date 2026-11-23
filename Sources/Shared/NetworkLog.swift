//
//  NetworkLog.swift
//  ID3Maps — shared by app, Intents extension and widget.
//
//  Logs every change of the phone's network path (online/offline, Wi-Fi/mobile, which
//  interfaces exist), so a "connection lost" in Maps can be matched against what the network
//  did at that moment - e.g. the phone sitting on the car's Wi-Fi without internet.
//

import Foundation
import Network

final class NetworkLog: @unchecked Sendable {
    static let shared = NetworkLog()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.porsche.one.netlog")
    private let lock = NSLock()
    private var started = false
    private var current = "ukendt"

    /// Idempotent; the first path is logged right away.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: queue)
    }

    /// Short description of the current path, for other log lines.
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func update(_ path: NWPath) {
        let d = Self.describe(path)
        lock.lock()
        let changed = d != current
        current = d
        lock.unlock()
        if changed { SharedLog.shared.log("network: \(d)", category: "net") }
    }

    private static func name(_ t: NWInterface.InterfaceType) -> String {
        switch t {
        case .wifi: return "wifi"
        case .cellular: return "mobil"
        case .wiredEthernet: return "kabel"
        case .loopback: return "loopback"
        case .other: return "andet"
        @unknown default: return "?"
        }
    }

    private static func describe(_ p: NWPath) -> String {
        var parts: [String] = []
        switch p.status {
        case .satisfied: parts.append("online")
        case .unsatisfied: parts.append("OFFLINE")
        case .requiresConnection: parts.append("venter på forbindelse")
        @unknown default: parts.append("?")
        }
        let used = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other].filter { p.usesInterfaceType($0) }
        if !used.isEmpty { parts.append("via " + used.map(name).joined(separator: "+")) }
        let avail = Array(Set(p.availableInterfaces.map { name($0.type) })).sorted()
        if !avail.isEmpty { parts.append("tilgængelige: " + avail.joined(separator: ", ")) }
        if p.isExpensive { parts.append("dyr") }
        if p.isConstrained { parts.append("datasparetilstand") }
        return parts.joined(separator: ", ")
    }
}
