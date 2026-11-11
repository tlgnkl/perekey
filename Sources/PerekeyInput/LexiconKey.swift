// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore
import Security

/// Where the key of the personal lexicon lives (docs/classifier.md, «Личный
/// словарь»). The key is what makes the fingerprints in `lexicon.json` say
/// nothing: whoever has the file but not the key cannot check a guessed word
/// against it. So the key is never in a file, and there is no spare key
/// anywhere: when the store cannot reach it, the lexicon is off.
public protocol LexiconKeyStore: Sendable {
    /// The key, nil when there is none (or what is stored is no key).
    func load() throws -> PersonalKey?
    /// Draws a new key and keeps it over any older one.
    func create() throws -> PersonalKey
    /// Removes the key; no key is not an error.
    func delete() throws
}

public enum LexiconKeyFailure: Error, Hashable, Sendable {
    /// The Keychain refused, with its status.
    case status(OSStatus)
    /// The system's random source failed, or gave only zeros.
    case noRandomKey
}

/// Draws the key from the system's random source.
public enum LexiconKeyGenerator {
    /// Fills the buffer with random bytes; false when it cannot.
    public typealias Fill = @Sendable (inout [UInt8]) -> Bool

    /// `SecRandomCopyBytes`.
    public static let secure: Fill = { (bytes: inout [UInt8]) in
        bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) } == errSecSuccess
    }

    /// How many draws `make` tries. A draw of 16 zero bytes has a chance of
    /// 2⁻¹²⁸ from a working source, so a second one is for a source that is
    /// broken, and a third is for being sure; more would only hide a failure
    /// that must turn the lexicon off.
    static let attempts = 3

    /// A key of 16 random bytes. A draw that is all zeros is no draw
    /// (`PersonalKey(bytes:)` refuses it): it is tried again, `attempts` times at most.
    public static func make(fill: Fill = secure) throws -> PersonalKey {
        for _ in 0..<attempts {
            var bytes = [UInt8](repeating: 0, count: PersonalKey.byteCount)
            guard fill(&bytes) else { throw LexiconKeyFailure.noRandomKey }
            if let key = PersonalKey(bytes: bytes) { return key }
        }
        throw LexiconKeyFailure.noRandomKey
    }
}

extension PersonalKey {
    /// The 16 bytes as `PersonalKey(bytes:)` takes them.
    var bytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: k0 >> (8 * UInt64($0))) }
            + (0..<8).map { UInt8(truncatingIfNeeded: k1 >> (8 * UInt64($0))) }
    }
}

/// The key in the login keychain: one generic password, service
/// `app.perekey.Perekey.lexicon`, account `key-v1`, readable after the first
/// unlock, on this device only and never synchronized. Perekey made the item,
/// so reading it asks nothing of the user.
public struct KeychainLexiconKeyStore: LexiconKeyStore {
    public static let service = "app.perekey.Perekey.lexicon"
    public static let account = "key-v1"

    public let service: String
    private let fill: LexiconKeyGenerator.Fill
    /// A keychain file to use instead of the login keychain: for tests.
    /// `nonisolated(unsafe)`, as in `VoiceKeychain`: a `SecKeychain` is a
    /// Core Foundation object with no Sendable annotation. It is set once in
    /// `init`, never changed, and only handed to the Security calls, which
    /// are thread-safe. Production code leaves it nil.
    nonisolated(unsafe) let keychain: SecKeychain?

    public init(service: String = KeychainLexiconKeyStore.service) {
        self.service = service
        fill = LexiconKeyGenerator.secure
        keychain = nil
    }

    init(service: String, keychain: SecKeychain, fill: @escaping LexiconKeyGenerator.Fill = LexiconKeyGenerator.secure) {
        self.service = service
        self.keychain = keychain
        self.fill = fill
    }

    public func load() throws -> PersonalKey? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LexiconKeyFailure.status(status) }
        return (value as? Data).flatMap { PersonalKey(bytes: $0) }
    }

    public func create() throws -> PersonalKey {
        let key = try LexiconKeyGenerator.make(fill: fill)
        try delete()
        var item = Self.attributes(of: base, data: Data(key.bytes))
        if let keychain { item[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LexiconKeyFailure.status(status) }
        return key
    }

    /// What the item is made of: the data, a label, readable after the first
    /// unlock, this device only. A file keychain does not hand the accessibility
    /// back, so the test reads it here.
    static func attributes(of base: [String: Any], data: Data) -> [String: Any] {
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Perekey: my words"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        return item
    }

    public func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LexiconKeyFailure.status(status) }
    }

    var base: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: Self.account,
                                    kSecAttrSynchronizable as String: false]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }
}

/// A key held in memory: for the logic's tests, for snapshots of the window
/// and for the typing recording (`PersonalLexiconStore`), where no key may
/// reach a keychain or a file. `setFailure` makes every call throw.
public final class MemoryLexiconKeyStore: LexiconKeyStore, Sendable {
    private struct State {
        var key: PersonalKey?
        var failure: (any Error)?
        var drawn = 0
        var deletes = 0
        var loads = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let fill: LexiconKeyGenerator.Fill

    public init(key: PersonalKey? = nil, failure: (any Error)? = nil,
                fill: @escaping LexiconKeyGenerator.Fill = LexiconKeyGenerator.secure)
    {
        state = OSAllocatedUnfairLock(initialState: State(key: key, failure: failure))
        self.fill = fill
    }

    /// How many keys `create` drew.
    public var created: Int { state.withLock { $0.drawn } }

    /// How many times `load` was called, failed or not.
    public var loaded: Int { state.withLock { $0.loads } }

    /// How many times `delete` was called, failed or not.
    public var deleted: Int { state.withLock { $0.deletes } }

    public func setFailure(_ error: (any Error)?) {
        state.withLock { $0.failure = error }
    }

    public func load() throws -> PersonalKey? {
        try state.withLock {
            $0.loads += 1
            if let failure = $0.failure { throw failure }
            return $0.key
        }
    }

    public func create() throws -> PersonalKey {
        try state.withLock {
            if let failure = $0.failure { throw failure }
            let made = try LexiconKeyGenerator.make(fill: fill)
            $0.key = made
            $0.drawn += 1
            return made
        }
    }

    public func delete() throws {
        try state.withLock {
            $0.deletes += 1
            if let failure = $0.failure { throw failure }
            $0.key = nil
        }
    }
}
