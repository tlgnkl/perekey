// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct SettingsTransferTests {
    @Test func exportThenImportRoundTrips() throws {
        var settings = AppSettings(capsLock: .system, words: WordExceptions(mine: ["слово"]))
        settings.setTrigger(.key(keyCode: 14, modifiers: [.control]), for: .selectLanguage("en"))
        let data = try SettingsTransfer.export(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\n"))
        #expect(text.contains("\"version\""))
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
}
