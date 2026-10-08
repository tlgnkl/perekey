// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct SettingsTransferTests {
    @Test func exportThenImportRoundTrips() throws {
        var settings = AppSettings(capsLock: .system, words: WordRules(
            mine: ["слово"], learned: [LearnedWord(word: "ghbdtn", learnedAt: 10, undoCount: 3, lastUndoneAt: 30)],
            always: ["аня"]
        ))
        settings.setTrigger(.key(keyCode: 14, modifiers: [.control]), for: .selectLanguage("en"))
        let data = try SettingsTransfer.export(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"version\" : 2"))
        #expect(try SettingsTransfer.importSettings(from: data) == settings)
    }

    @Test func rejectsForeignJSON() {
        for text in ["", "[]", "{}", #"{"name":"x"}"#, #"{"hotkeys":"nope"}"#, #"{"autoswitch":true,"version":"x"}"#] {
            #expect(throws: SettingsTransfer.ImportError.self) {
                try SettingsTransfer.importSettings(from: Data(text.utf8))
            }
        }
    }

    @Test func rejectsNewerVersion() {
        #expect(throws: SettingsTransfer.ImportError.newerVersion(99)) {
            try SettingsTransfer.importSettings(from: Data(#"{"autoswitch":true,"version":99}"#.utf8))
        }
    }

    @Test func acceptsFileWithoutVersion() throws {
        let settings = try SettingsTransfer.importSettings(from: Data(#"{"autoswitch":false}"#.utf8))
        #expect(!settings.autoswitch)
    }

    /// An export of Perekey before "Всегда исправлять" and the undo count (format 1).
    @Test func importsAVersion1Export() throws {
        let file = #"""
        {
          "autoswitch" : true,
          "capsLock" : "untouched",
          "hotkeys" : [],
          "onboardingDone" : true,
          "version" : 1,
          "words" : {
            "learnFromUndos" : false,
            "learned" : [ { "learnedAt" : 1790000000, "word" : "ghbdtn" } ],
            "mine" : [ "kubectl" ]
          }
        }
        """#
        let settings = try SettingsTransfer.importSettings(from: Data(file.utf8))
        #expect(settings.words == WordRules(mine: ["kubectl"],
                                            learned: [LearnedWord(word: "ghbdtn", learnedAt: 1_790_000_000)],
                                            learnFromUndos: false))
        #expect(settings.words.learned.first?.undoCount == 1)
        #expect(settings.words.learned.first?.lastUndoneAt == 1_790_000_000)
        #expect(SettingsTransfer.Summary(settings).words == 2)
    }

    @Test func summaryCountsAlwaysFixWords() {
        let settings = AppSettings(words: WordRules(mine: ["a"], always: ["аня", "гошан"]))
        #expect(SettingsTransfer.Summary(settings).words == 3)
    }
}
