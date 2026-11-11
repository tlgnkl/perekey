// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct PersonalLexiconFileTests {
    private let key = PersonalKey(bytes: (1...16).map { UInt8($0) })!

    private func withFile(_ body: (PersonalLexiconFile, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-lexicon-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(PersonalLexiconFile(url: directory.appending(path: "nested/lexicon.json")), directory)
    }

    /// A word accepted with its starts, and a candidate without.
    private func sampleModel() -> PersonalLexiconModel {
        var model = PersonalLexiconModel()
        let word = PersonalObservation(word: 0x00AB_CDEF_0123_4567, start3: 0x1111, start4: 0x2222, language: "ru")
        for day in [10, 11, 12, 12, 13] {
            model.record(PersonalTally(observations: [word], generation: 0), day: day)
        }
        model.record(PersonalTally(observations: [
            PersonalObservation(word: 0xFFFF_0000_0000_0001, start3: 0x3333, start4: nil, language: "en"),
        ], generation: 0), day: 13)
        return model
    }

    @Test func theFileIsExactlyThis() throws {
        let data = try PersonalLexiconFile.encode(sampleModel(), key: key)
        let check = PersonalLexiconFile.keyCheck(key)
        #expect(check.count == 16)
        let expected = #"{"entries":[{"accepted":true,"count":5,"days":4,"fingerprint":"00abcdef01234567","language":"ru","lastDay":13,"start3":"0000000000001111","start4":"0000000000002222"},"#
            + #"{"accepted":false,"count":1,"days":1,"fingerprint":"ffff000000000001","language":"en","lastDay":13}],"keyCheck":""#
            + check + #"","version":1}"#
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test func twoWritesOfTheSameLexiconAreTheSameBytes() throws {
        #expect(try PersonalLexiconFile.encode(sampleModel(), key: key) == PersonalLexiconFile.encode(sampleModel(), key: key))
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withFile { file, _ in
            try file.save(sampleModel(), key: key)
            let loaded = file.load(key: key)
            #expect(loaded.entries == sampleModel().entries)
            #expect(loaded.acceptedCount == 1)
            #expect(loaded.candidateCount == 1)
        }
    }

    @Test func theFileHoldsNoTextAndNoKeylessFingerprint() throws {
        // A secret word is observed, counted and written. Nothing of it may be in the file: not the text, not
        // its scalars, not the unkeyed fingerprint of the model (`Fingerprint.of`), not the key.
        let secret = "секретнословоарахис"
        let language: LanguageCode = "ru"
        var model = PersonalLexiconModel()
        let fingerprint = key.fingerprint(ofWord: secret, language: language)
        let starts = (key.fingerprint(.start3, language: language, secret.unicodeScalars.prefix(3).map(\.value)),
                      key.fingerprint(.start4, language: language, secret.unicodeScalars.prefix(4).map(\.value)))
        let observation = PersonalObservation(word: fingerprint, start3: starts.0, start4: starts.1, language: language)
        for day in 1...5 { model.record(PersonalTally(observations: [observation], generation: 0), day: day) }
        #expect(model.acceptedCount == 1)
        let data = try PersonalLexiconFile.encode(model, key: key)
        let json = String(decoding: data, as: UTF8.self)
        let unkeyed = [ModelFormat.Fingerprint.of(secret.unicodeScalars, folded: true),
                       ModelFormat.Fingerprint.of(secret.unicodeScalars, folded: false)]
        for hash in unkeyed {
            #expect(!json.contains(String(hash, radix: 16)), "the keyless fingerprint says which word it is")
            #expect(!json.contains(String(hash)))
        }
        for text in [secret, "секрет", "арахис", "секр", "арах"] { #expect(!json.contains(text)) }
        // UTF-8 and UTF-16 of the text, and of its first letters: no bytes of it at all.
        #expect(data.range(of: Data(secret.utf8)) == nil)
        #expect(data.range(of: Data("секр".utf8)) == nil)
        #expect(!json.unicodeScalars.contains { $0.value > 0x7F }, "an all-ASCII file has no letters of any alphabet")
        #expect(!json.contains(PersonalLexiconFile.hex(key.k0)), "the key is not in the file")
        #expect(!json.contains(PersonalLexiconFile.hex(key.k1)))
        // The words the model never saw are not there either.
        #expect(json.contains(PersonalLexiconFile.hex(fingerprint)), "the keyed fingerprint is the file's content")
    }

    @Test func fileIsForTheOwnerOnly() throws {
        try withFile { file, _ in
            for _ in 0..<2 {
                try file.save(sampleModel(), key: key)
                let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
                #expect(mode == 0o600)
            }
        }
    }

    @Test func anOpenFileIsClosedToTheOwner() throws {
        try withFile { file, directory in
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
            try file.save(sampleModel(), key: key)
            let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.url.deletingLastPathComponent().path)
            #expect(leftovers == ["lexicon.json"])
            _ = directory
        }
    }

    @Test func anUnreadableFileIsAnEmptyLexicon() throws {
        try withFile { file, _ in
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            for bad in ["not json", "", "{}", #"{"version":1}"#, #"{"entries":[],"keyCheck":"x","version":1}"#] {
                try Data(bad.utf8).write(to: file.url)
                let loaded = file.load(key: key)
                #expect(loaded.entries.isEmpty, "\(bad)")
            }
        }
    }

    @Test func anEntryThatIsNoFingerprintSpoilsTheFile() throws {
        try withFile { file, _ in
            try file.save(sampleModel(), key: key)
            let good = try String(contentsOf: file.url, encoding: .utf8)
            for (from, to) in [("00abcdef01234567", "00ABCDEF01234567"), ("00abcdef01234567", "00abcdef0123456"),
                               ("00abcdef01234567", "00abcdef0123456g"), ("0000000000001111", "11"),
                               (#""count":5"#, #""count":0"#), (#""days":4"#, #""days":6"#),
                               (#""language":"ru""#, #""language":"r""#), (#""version":1"#, #""version":2"#)]
            {
                try Data(good.replacingOccurrences(of: from, with: to).utf8).write(to: file.url)
                #expect(file.load(key: key).entries.isEmpty, "\(from) → \(to)")
            }
        }
    }

    @Test func aFileWrittenUnderAnotherKeyIsAnEmptyLexicon() throws {
        try withFile { file, _ in
            try file.save(sampleModel(), key: key)
            let other = PersonalKey(bytes: (1...16).map { UInt8(17 - $0) })!
            #expect(file.load(key: other).entries.isEmpty)
            #expect(file.load(key: key).entries.count == 2)
        }
    }

    @Test func theLoadedLexiconKeepsTheOptionsAndTheGeneration() throws {
        try withFile { file, _ in
            try file.save(sampleModel(), key: key)
            var options = PersonalOptions()
            options.promoteCount = 9
            let loaded = file.load(key: key, options: options, generation: 7)
            #expect(loaded.options.promoteCount == 9)
            #expect(loaded.generation == 7)
        }
    }

    @Test func removeDeletesTheFileAndNoFileIsNoError() throws {
        try withFile { file, _ in
            try file.remove()
            try file.save(sampleModel(), key: key)
            #expect(file.exists)
            try file.remove()
            #expect(!file.exists)
        }
    }
}
