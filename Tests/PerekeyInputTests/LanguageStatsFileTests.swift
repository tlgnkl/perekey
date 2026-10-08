// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct LanguageStatsFileTests {
    /// Runs `body` with a stats file in a fresh temporary directory.
    private func withFile(_ body: (LanguageStatsFile) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-languages-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LanguageStatsFile(url: directory.appending(path: "nested/languages.json")))
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withFile { file in
            #expect(file.load() == LanguageStats())
            var stats = LanguageStats()
            stats.record(LanguageTally(app: "org.telegram.desktop", site: nil, words: ["ru": 40, "en": 3]), at: 100)
            stats.record(LanguageTally(app: "com.apple.Safari", site: "github.com", words: ["en": 12]), at: 200)
            try file.save(stats)
            #expect(file.load() == stats)
        }
    }

    @Test func anUnreadableFileStartsOver() throws {
        try withFile { file in
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: file.url)
            #expect(file.load() == LanguageStats())
        }
    }

    @Test func theFileHoldsOnlyNamesCodesAndNumbers() throws {
        var stats = LanguageStats()
        stats.record(LanguageTally(app: "org.telegram.desktop", site: "mail.example", words: ["ru": 40]), at: 100)
        let json = try #require(String(data: LanguageStatsFile.encode(stats), encoding: .utf8))
        #expect(json == #"{"apps":{"org.telegram.desktop":{"updated":100,"words":{"ru":40}}},"#
            + #""sites":{"mail.example":{"updated":100,"words":{"ru":40}}},"version":1}"#)
    }
}
