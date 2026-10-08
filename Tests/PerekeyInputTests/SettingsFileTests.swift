// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct SettingsFileTests {
    /// Runs `body` with a settings file in a fresh temporary directory.
    private func withFile(_ body: (SettingsFile) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(SettingsFile(url: directory.appending(path: "nested/settings.json")))
    }

    private func write(_ text: String, to file: SettingsFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    @Test func missingFileGivesDefaults() throws {
        try withFile { file in
            #expect(file.load() == AppSettings())
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withFile { file in
            var settings = AppSettings()
            settings.apply(.separateKeys)
            settings.capsLock = .system
            settings.autoswitch = false
            settings.setTrigger(.key(keyCode: 49, modifiers: [.control, .option]), for: .switchLayout)
            try file.save(settings)
            #expect(file.load() == settings)
        }
    }

    @Test func corruptFileIsMovedAside() throws {
        try withFile { file in
            try write("{ not json", to: file)
            #expect(file.load() == AppSettings())
            #expect(!FileManager.default.fileExists(atPath: file.url.path))
            #expect(try Data(contentsOf: file.brokenURL) == Data("{ not json".utf8))
        }
    }

    @Test func saveAfterCorruptionKeepsTheCopy() throws {
        try withFile { file in
            try write("[1,2", to: file)
            _ = file.load()
            try file.save(AppSettings())
            #expect(FileManager.default.fileExists(atPath: file.brokenURL.path))
            #expect(file.load() == AppSettings())
        }
    }
}
