//
//  SharedStore.swift
//  ID3Maps — shared between app and Intents extension.
//
//  Small key/value store in the shared keychain access group (App Groups are
//  unavailable under the wildcard profile). Holds the Worker status token (typed
//  once in the app) and the last known vehicle state (so Maps still gets an
//  answer when the Worker is unreachable).
//

import Foundation

enum SharedStore {
    enum Key: String {
        case statusToken = "status-token"
        case lastState = "last-state"
    }

    private static let service = "com.porsche.one.store"

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessGroup as String: SharedConfig.keychainAccessGroup,
        ]
    }

    static func data(_ key: Key) -> Data? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func set(_ data: Data?, for key: Key) {
        let q = baseQuery(key)
        guard let data else {
            SecItemDelete(q as CFDictionary)
            return
        }
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(q as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func string(_ key: Key) -> String? {
        data(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setString(_ value: String?, for key: Key) {
        set(value?.data(using: .utf8), for: key)
    }

    static func codable<T: Decodable>(_ key: Key) -> T? {
        data(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func setCodable<T: Encodable>(_ value: T, for key: Key) {
        set(try? JSONEncoder().encode(value), for: key)
    }
}
