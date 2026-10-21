// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct DictationInsertionTests {
    @Test func terminalsTypeAndEditorsPaste() {
        for id in AppModes.terminalBundleIDs + ["com.stablyai.orca", "org.tabby", "co.zeit.hyper"] {
            #expect(DictationInsertion.automatic.types("ls", bundleID: id), "\(id)")
        }
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.pycharm",
                   "com.apple.TextEdit"]
        {
            #expect(!DictationInsertion.automatic.types("ls", bundleID: id), "\(id)")
        }
        #expect(!DictationInsertion.automatic.types("ls", bundleID: nil))
    }

    @Test func aLineBreakOrAControlCharacterIsNeverTyped() {
        for text in ["a\nb", "a\rb", "a\r\nb", "a\u{2028}b", "a\u{2029}b", "a\tb", "a\u{1B}[Ab", "a\u{7F}", "a\u{85}b"] {
            #expect(!DictationInsertion.canType(text), "\(text.debugDescription)")
            #expect(!DictationInsertion.automatic.types(text, bundleID: "com.apple.Terminal"))
            #expect(!DictationInsertion.typing.types(text, bundleID: "com.apple.Terminal"))
        }
        for text in ["Привет, мир", "naïve café", "😀 👨‍👩‍👧", "e\u{301}", "a\u{00A0}b"] {
            #expect(DictationInsertion.canType(text), "\(text.debugDescription)")
        }
    }

    @Test func theUsersChoiceWins() {
        #expect(DictationInsertion.typing.types("text", bundleID: "com.microsoft.VSCode"))
        #expect(!DictationInsertion.paste.types("text", bundleID: "com.apple.Terminal"))
    }

    @Test func voiceSettingsKeepTheChoicePerApp() throws {
        var settings = VoiceSettings()
        #expect(settings.insertion(bundleID: "com.apple.Terminal") == .automatic)
        #expect(settings.insertion(bundleID: nil) == .automatic)
        settings.insertion["com.microsoft.VSCode"] = .typing
        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["insertion"] as? [String: String] == ["com.microsoft.VSCode": "typing"])
        let read = try JSONDecoder().decode(VoiceSettings.self, from: data)
        #expect(read == settings)
        #expect(read.insertion(bundleID: "com.microsoft.VSCode") == .typing)
    }

    @Test func aFileWithoutTheKeyIsAutomatic() throws {
        let old = Data(#"{"schemaVersion":1,"isEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: old)
        #expect(settings.insertion.isEmpty)
        #expect(settings.unreadableKeys.isEmpty)
    }

    @Test func aChoiceOfALaterVersionIsKeptUntilTheUserChooses() throws {
        let later = Data(#"{"schemaVersion":1,"isEnabled":true,"insertion":{"com.apple.Terminal":"dictate"}}"#.utf8)
        var settings = try JSONDecoder().decode(VoiceSettings.self, from: later)
        #expect(settings.insertion.isEmpty)
        #expect(settings.unreadableKeys == ["insertion"])
        #expect(settings.activeTrigger == .default, "dictation stays on")
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(saved["insertion"] == nil, "the file keeps its value")
        settings.insertion["com.apple.Terminal"] = .paste
        #expect(settings.unreadableKeys.isEmpty)
    }
}
