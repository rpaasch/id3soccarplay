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
    static let keychainAccessGroup = "com.porsche.one.shared"
    static let logService = "com.porsche.one.log"
    static let maxEntries = 400
}

/// One log line.
struct LogEntry: Sendable, Codable, Identifiable {
    enum Source: String, Sendable, Codable { case app, ext }
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
final class SharedLog: @unchecked Sendable {
    static let shared = SharedLog()

    private let queue = DispatchQueue(label: "com.porsche.one.sharedlog")
    private let source: LogEntry.Source

    private init() {
        // Identify which process is writing, by bundle id suffix.
        let bid = Bundle.main.bundleIdentifier ?? ""
        source = bid.hasSuffix(".extension") ? .ext : .app
    }

    /// Appends a line and mirrors it to the unified log for good measure.
    func log(_ message: String, category: String = "general") {
        let entry = LogEntry(source: source, category: category, message: message)
        NSLog("[ID3Maps/%@/%@] %@", source.rawValue, category, message)
        queue.sync {
            var entries = Self.readRaw()
            entries.append(entry)
            if entries.count > SharedConfig.maxEntries {
                entries.removeFirst(entries.count - SharedConfig.maxEntries)
            }
            Self.writeRaw(entries)
        }
    }

    /// All entries, oldest first.
    func entries() -> [LogEntry] {
        queue.sync { Self.readRaw() }
    }

    /// Clears the log.
    func clear() {
        queue.sync { Self.writeRaw([]) }
    }

    /// Plain-text export for the share sheet.
    func exportText() -> String {
        let df = ISO8601DateFormatter()
        return entries().map { e in
            "\(df.string(from: e.date)) [\(e.source.rawValue)/\(e.category)] \(e.message)"
        }.joined(separator: "\n")
    }

    // MARK: - Keychain raw access

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedConfig.logService,
            kSecAttrAccount as String: "shared",
            kSecAttrAccessGroup as String: SharedConfig.keychainAccessGroup,
        ]
    }

    private static func readRaw() -> [LogEntry] {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let entries = try? JSONDecoder().decode([LogEntry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeRaw(_ entries: [LogEntry]) {
        let data = (try? JSONEncoder().encode(entries)) ?? Data()
        let q = baseQuery()
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
