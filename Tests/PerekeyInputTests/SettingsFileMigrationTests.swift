// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct SettingsFileMigrationTests {
    static func fileAndDefaults() throws -> (SettingsFile, UserDefaults, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-\(UUID().uuidString)")
        let name = "perekey-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let url = directory.appending(path: "settings.json")
        return (SettingsFile(url: url, defaults: defaults), defaults, directory)
    }

    /// What an older build writes back: no `learning`, `candidates` or `app`.
    static func savedByOlderBuild(_ url: URL) throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var words = try #require(object["words"] as? [String: Any])
        words["learning"] = nil
        words["candidates"] = nil
        words["learned"] = (words["learned"] as? [[String: Any]])?.map { $0.filter { $0.key != "app" } }
        var rolledBack = object
        rolledBack["words"] = words
        try JSONSerialization.data(withJSONObject: rolledBack).write(to: url)
    }

    @Test func rollbackKeepsWordsLearnedByEvidence() throws {
        let (file, defaults, directory) = try Self.fileAndDefaults()
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings()
        // Learned by evidence at threshold 1: one button undo.
        settings.words.learned = [LearnedWord(word: "jrtq", learnedAt: 1_790_000_000, undoCount: 1,
                                              lastUndoneAt: 1_790_000_000)]
        try file.save(settings)
        defaults.set(true, forKey: "learningMigrated")
        try Self.savedByOlderBuild(file.url)
        let back = file.load()
        #expect(back.words.learned.map(\.word) == ["jrtq"])
        #expect(back.words.candidates.isEmpty)
    }

    @Test func fileWithoutLearningMigratesOnceOnLoad() throws {
        let (file, _, directory) = try Self.fileAndDefaults()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = #"{"words":{"learned":[{"word":"jrtq","learnedAt":5,"lastUndoneAt":5}]}}"#
        try Data(old.utf8).write(to: file.url)
        let before = Date().timeIntervalSince1970
        let first = file.load()
        #expect(first.words.learned.isEmpty)
        let candidate = try #require(first.words.candidates.first)
        #expect(candidate.lastCountedAt >= before, "counts from the migration, so it does not expire at once")
        // Saved by an older build again: the mark is on, so nothing migrates twice.
        try Data(old.utf8).write(to: file.url)
        #expect(file.load().words.learned.map(\.word) == ["jrtq"])
    }

    @Test func migratedSettingsAreOnDiskBeforeTheMarkIsSet() throws {
        let (file, defaults, directory) = try Self.fileAndDefaults()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"words":{"learned":[{"word":"jrtq","learnedAt":5,"lastUndoneAt":5}]}}"#.utf8).write(to: file.url)
        _ = file.load()
        #expect(defaults.bool(forKey: "learningMigrated"))
        // Quit before any change: the next launch reads the migrated file, with `learning`.
        let saved = try String(contentsOf: file.url, encoding: .utf8)
        #expect(saved.contains("\"learning\""))
        #expect(file.load().words.candidates.map(\.word) == ["jrtq"])
    }

    @Test func markStaysOffWhenTheMigratedFileCannotBeWritten() throws {
        let (file, defaults, directory) = try Self.fileAndDefaults()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"words":{"learned":[{"word":"jrtq","learnedAt":5}]}}"#.utf8).write(to: file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        _ = file.load()
        #expect(!defaults.bool(forKey: "learningMigrated"))
    }

    @Test func importKeepsLearnedWordsOfAnOlderFile() throws {
        let old = #"{"words":{"learned":[{"word":"jrtq","learnedAt":5}]}}"#
        let words = try SettingsTransfer.importSettings(from: Data(old.utf8)).words
        #expect(words.learned.map(\.word) == ["jrtq"] && words.candidates.isEmpty)
    }
}
