// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

/// API keys of the voice endpoints, in the login keychain: one generic
/// password per endpoint, the endpoint's id as the account. Keys are never
/// written to a file or a log; reading one does not ask the user, since
/// Perekey made the item.
public struct VoiceKeychain: Sendable {
    public static let service = "app.perekey.Perekey.voice-endpoints"

    public enum Failure: Error, Hashable, Sendable {
        case status(OSStatus)
    }

    public let service: String

    public init(service: String = VoiceKeychain.service) {
        self.service = service
    }

    /// The key of `endpoint`, nil when there is none.
    public func key(for endpoint: String) throws -> String? {
        var query = base(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Whether `endpoint` has a key, without reading it.
    public func hasKey(for endpoint: String) -> Bool {
        var query = base(endpoint)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `key` for `endpoint`, over the one there was. An empty key removes it.
    public func set(_ key: String, for endpoint: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try remove(endpoint) }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(base(endpoint) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base(endpoint)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Perekey: \(endpoint)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    public func remove(_ endpoint: String) throws {
        let status = SecItemDelete(base(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    /// Removes every key of the service: for tests.
    func removeAll() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.status(status) }
    }

    private func base(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: endpoint]
    }
}
