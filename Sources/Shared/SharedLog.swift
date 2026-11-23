//
//  SharedLog.swift
//  ID3Maps — shared between app and Intents extension.
//
//  An in-app log shared across the two processes via a *shared keychain access
//  group* (App Groups are unavailable under the wildcard `com.porsche.*`
//  provisioning profile — see docs/M-1). This is the single most important M0
//  tool: we cannot see the device console, so every intent call from Maps is
//  recorded here and can be exported from the app via the share sheet.
//
//  Storage: one keychain item holding a JSON array, kept as a ring buffer.
//  Concurrency is best-effort (last-writer-wins); good enough for M0 where the
//  extension appends and the app reads.
//

import Foundation

/// Keychain access group shared by app + extension. Matches the entitlements.
/// `$(AppIdentifierPrefix)` is supplied by the system at runtime, so the code
/// uses the bare group and lets the keychain resolve the team prefix.
enum SharedConfig {
    /// Full keychain access group, including the team prefix. The Ad Hoc profile
    /// grants `XY6GZ256WA.*`, and both app and extension request
    /// `$(AppIdentifierPrefix)com.porsche.one.shared` in their entitlements, so
    /// the runtime access group is the team id + that group.
    static let keychainAccessGroup = "XY6GZ256WA.com.porsche.one.shared"
    static let logService = "com.porsche.one.log"
    /// Per process (app, extension, widget each keep their own ring buffer).
    static let maxEntries = 1500
}

/// One log line.
struct LogEntry: Sendable, Codable, Identifiable {
    enum Source: String, Sendable, Codable { case app, ext, widget }
    let id: UUID
    let date: Date
    let source: Source
    let category: String
    let message: String

    init(source: Source, category: String, message: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.source = source
        self.category = category
        self.message = message
    }
}

/// Thread-safe facade over the shared keychain log.
///
/// Each process writes its own keychain item (no more lost lines when the app and the extension
/// write at the same moment), and writes are batched off the caller's thread: logging never
/// delays an answer to Maps. Reading merges all processes in time order.
final class SharedLog: @unchecked Sendable {
    static let shared = SharedLog()

    private let queue = DispatchQueue(label: "com.porsche.one.sharedlog")
    private let source: LogEntry.Source
    private var pending: [LogEntry] = []
    private var flushScheduled = false
    /// Keychain accounts: one per process, plus the old shared one (read and cleared only).
    private static let accounts = ["app", "ext", "widget", "shared"]

    private init() {
        // Identify which process is writing, by bundle id suffix.
        let bid = Bundle.main.bundleIdentifier ?? ""
        source = bid.hasSuffix(".extension") ? .ext : bid.hasSuffix(".widget") ? .widget : .app
    }

    /// Appends a line (written within ~0.3 s) and mirrors it to the unified log.
    func log(_ message: String, category: String = "general") {
        let entry = LogEntry(source: source, category: category, message: message)
        NSLog("[ID3Maps/%@/%@] %@", source.rawValue, category, message)
        queue.async {
            self.pending.append(entry)
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.flushLocked() }
        }
    }

    /// Writes pending lines now (e.g. before the process may be suspended).
    func flush() {
        queue.sync { flushLocked() }
    }

    private func flushLocked() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var entries = Self.readRaw(source.rawValue)
        entries.append(contentsOf: pending)
        pending.removeAll()
        if entries.count > SharedConfig.maxEntries {
            entries.removeFirst(entries.count - SharedConfig.maxEntries)
        }
        Self.writeRaw(entries, account: source.rawValue)
    }

    /// All entries of all processes, oldest first.
    func entries() -> [LogEntry] {
        queue.sync {
            flushLocked()
            return Self.accounts.flatMap { Self.readRaw($0) }.sorted { $0.date < $1.date }
        }
    }

    /// Clears the log of all processes.
    func clear() {
        queue.sync {
            pending.removeAll()
            for a in Self.accounts { Self.writeRaw([], account: a) }
        }
    }

    /// Plain-text export for the share sheet.
    func exportText() -> String {
        let df = ISO8601DateFormatter()
        return entries().map { e in
            "\(df.string(from: e.date)) [\(e.source.rawValue)/\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }

    // MARK: - Keychain raw access

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.logService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SharedConfig.keychainAccessGroup,
        ]
    }

    private static func readRaw(_ account: String) -> [LogEntry] {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let entries = try? JSONDecoder().decode([LogEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeRaw(_ entries: [LogEntry], account: String) {
        let data = (try? JSONEncoder().encode(entries)) ?? Data()
        let q = baseQuery(account)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
