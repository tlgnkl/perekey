// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore
import Security
import Testing
@testable import PerekeyInput

struct LexiconKeyTests {
    @Test func theSystemDrawGivesAKeyOf16BytesThatIsNotZero() throws {
        let first = try LexiconKeyGenerator.make()
        let second = try LexiconKeyGenerator.make()
        #expect(!first.isZero)
        #expect(first.bytes.count == PersonalKey.byteCount)
        #expect(first != second, "two draws of 128 bits are never the same")
        #expect(PersonalKey(bytes: first.bytes) == first, "the bytes read back as the same key")
    }

    @Test func aBufferNobodyFilledIsNoKey() {
        // The source reports success and leaves zeros: `PersonalKey(bytes:)` refuses, the draw is repeated, then given up.
        let draws = OSAllocatedUnfairLock(initialState: 0)
        #expect(throws: LexiconKeyFailure.noRandomKey) {
            try LexiconKeyGenerator.make { _ in
                draws.withLock { $0 += 1 }
                return true
            }
        }
        #expect(draws.withLock { $0 } == 3)
    }

    @Test func aDrawThatFailsIsNoKey() {
        #expect(throws: LexiconKeyFailure.noRandomKey) { try LexiconKeyGenerator.make { _ in false } }
    }

    @Test func aZeroDrawIsRepeatedAndTheNextOneIsTaken() throws {
        let draws = OSAllocatedUnfairLock(initialState: 0)
        let key = try LexiconKeyGenerator.make { bytes in
            let number = draws.withLock { state -> Int in
                state += 1
                return state
            }
            if number > 1 { bytes = (0..<16).map { UInt8($0 + 1) } }
            return true
        }
        #expect(draws.withLock { $0 } == 2)
        #expect(key.bytes == (0..<16).map { UInt8($0 + 1) })
    }

    @Test func theMemoryStoreKeepsOneKeyUntilItIsDeleted() throws {
        let keys = MemoryLexiconKeyStore()
        #expect(try keys.load() == nil)
        let made = try keys.create()
        #expect(try keys.load() == made)
        let again = try keys.create()
        #expect(again != made, "create keeps a new key over the old one")
        #expect(try keys.load() == again)
        try keys.delete()
        #expect(try keys.load() == nil)
        try keys.delete()
    }

    @Test func theMemoryStoreCanFail() {
        let keys = MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25293))
        #expect(throws: LexiconKeyFailure.status(-25293)) { try keys.load() }
        #expect(throws: LexiconKeyFailure.status(-25293)) { try keys.create() }
        keys.setFailure(nil)
        #expect(throws: Never.self) { try keys.create() }
    }
}

struct KeychainLexiconKeyStoreTests {
    /// A keychain file of its own, unlocked, removed after the test: the
    /// login keychain is not touched, and need not be reachable.
    private func withKeychain(_ body: (SecKeychain, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "test.keychain-db").path
        let password = "perekey-test"
        var file: SecKeychain?
        // SecKeychainCreate is deprecated, and the only way to a keychain file
        // of one's own that needs no user interaction.
        let created = password.withCString { SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &file) }
        try #require(created == errSecSuccess)
        let made = try #require(file)
        defer { SecKeychainDelete(made) }
        try body(made, "app.perekey.tests.\(UUID().uuidString)")
    }

    @Test func theKeyRoundTripsAndNewOnesReplaceIt() throws {
        try withKeychain { keychain, service in
            let store = KeychainLexiconKeyStore(service: service, keychain: keychain)
            #expect(try store.load() == nil)
            let made = try store.create()
            #expect(!made.isZero)
            #expect(try store.load() == made)
            let replacement = try store.create()
            #expect(replacement != made)
            #expect(try store.load() == replacement)
            try store.delete()
            #expect(try store.load() == nil)
            try store.delete()
        }
    }

    @Test func theItemIsThisDevicesOnlyAndNeverSynchronized() {
        // A file keychain does not hand the accessibility back, so what is added is read from the dictionary.
        let store = KeychainLexiconKeyStore(service: "app.perekey.tests.x")
        let item = KeychainLexiconKeyStore.attributes(of: store.base, data: Data(repeating: 1, count: 16))
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(item[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(item[kSecAttrService as String] as? String == "app.perekey.tests.x")
        #expect(item[kSecAttrAccount as String] as? String == "key-v1")
        #expect(item[kSecClass as String] as? String == kSecClassGenericPassword as String)
    }

    @Test func theNamesAreThoseOfThePlan() {
        #expect(KeychainLexiconKeyStore.service == "app.perekey.Perekey.lexicon")
        #expect(KeychainLexiconKeyStore.account == "key-v1")
    }

    @Test func aDrawOfZerosStoresNothing() throws {
        try withKeychain { keychain, service in
            let store = KeychainLexiconKeyStore(service: service, keychain: keychain) { _ in true }
            #expect(throws: LexiconKeyFailure.noRandomKey) { try store.create() }
            let loaded = try store.load()
            #expect(loaded == nil)
        }
    }

    @Test func somethingThatIsNoKeyIsNoKey() throws {
        try withKeychain { keychain, service in
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: KeychainLexiconKeyStore.account,
                                       kSecAttrSynchronizable as String: false,
                                       kSecValueData as String: Data(repeating: 0, count: 16),
                                       kSecUseKeychain as String: keychain]
            #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
            let store = KeychainLexiconKeyStore(service: service, keychain: keychain)
            defer { try? store.delete() }
            let loaded = try store.load()
            #expect(loaded == nil, "16 zero bytes are no key")
        }
    }
}
