// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
import Testing
@testable import PerekeyInput

/// Decision Р1: the recording is switched on by hand. Every launch starts
/// with it off, whatever an older dev build left in the defaults.
@Suite struct RecordingPreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "perekey-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aSwitchLeftByAnOlderBuildIsRemovedAtLaunch() {
        let defaults = defaults()
        defaults.set(true, forKey: "sessionRecording")
        _ = RecordingPreferences(defaults: defaults)
        #expect(defaults.object(forKey: "sessionRecording") == nil)
    }

    @Test func theAppsTheUserAddedAreKept() {
        let defaults = defaults()
        RecordingPreferences(defaults: defaults).ownExcluded = ["com.example.Bank", "com.example.Mail"]
        #expect(RecordingPreferences(defaults: defaults).ownExcluded == ["com.example.Bank", "com.example.Mail"])
    }

    /// The app side keeps no switch: the file of `SessionRecording` starts it
    /// off and writes no `sessionRecording` key (it is in the app target,
    /// which the tests cannot link, so its text is checked).
    @Test func theAppNeverWritesTheSwitch() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Perekey/SessionRecording.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("private(set) var isOn = false"))
        #expect(!text.contains("defaults.set(on"))
        #expect(!text.contains("defaults.bool"))
    }
}
#endif
