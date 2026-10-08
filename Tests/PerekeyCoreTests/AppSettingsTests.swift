// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct AppSettingsTests {
    @Test func roundTrip() throws {
        var settings = AppSettings(capsLock: .instant)
        settings.setTrigger(.key(keyCode: 14, modifiers: [.control, .option]), for: .selectLanguage("en"))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test func missingKeysUseDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":false}"#.utf8))
        #expect(settings == AppSettings(autoswitch: false))
    }

    @Test func unknownCapsLockModeFallsBack() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"capsLock":"laser"}"#.utf8))
        #expect(settings.capsLock == .untouched)
    }

    @Test func caretHintDefaultsToAllEdits() throws {
        #expect(AppSettings().caretHint == .all)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.caretHint == .all)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"caretHint":"loud"}"#.utf8))
        #expect(unknown.caretHint == .all)
        let automatic = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"caretHint":"automatic"}"#.utf8))
        #expect(automatic.caretHint == .automatic)
    }

    @Test func caretHintModesDecideWhichEditsShow() {
        #expect(CaretHintMode.all.shows(automatic: true) && CaretHintMode.all.shows(automatic: false))
        #expect(CaretHintMode.automatic.shows(automatic: true) && !CaretHintMode.automatic.shows(automatic: false))
        #expect(!CaretHintMode.off.shows(automatic: true) && !CaretHintMode.off.shows(automatic: false))
    }

    @Test func onboardingIsNotDoneByDefault() throws {
        #expect(!AppSettings().onboardingDone)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(!old.onboardingDone)
        let done = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"onboardingDone":true}"#.utf8))
        #expect(done.onboardingDone)
    }

    @Test func presetFollowsShortcuts() {
        var settings = AppSettings()
        #expect(settings.preset == .standard)
        settings.setTrigger(.modifiers(.shift, taps: .double), for: .convertLastWord)
        #expect(settings.preset == .doubleShift)
        settings.setTrigger(nil, for: .toggleAutoswitch)
        #expect(settings.preset == nil)
    }

    @Test func instantCapsLockAddsF18() {
        let f18 = HotkeyBinding(.key(keyCode: KeyCode.f18, modifiers: []), action: .switchLayout)
        #expect(AppSettings(capsLock: .instant).snapshot.hotkeys.contains(f18))
        #expect(!AppSettings(capsLock: .system).snapshot.hotkeys.contains(f18))
    }
}

@Suite struct KeyRemappingTests {
    private let escape = KeyRemapping(source: KeyRemapping.capsLockUsage, destination: 0x7_0000_0029)
    private let other = KeyRemapping(source: 0x7_0000_0064, destination: 0x7_0000_0035) // § → `

    @Test func addingKeepsOthers() {
        #expect(KeyRemapping.adding(.capsLockToF18, to: [other]) == [other, .capsLockToF18])
        #expect(KeyRemapping.adding(.capsLockToF18, to: [other, .capsLockToF18]) == [other, .capsLockToF18])
    }

    @Test func addingReplacesCapsLockRemap() {
        #expect(KeyRemapping.adding(.capsLockToF18, to: [escape, other]) == [other, .capsLockToF18])
    }

    @Test func removingTouchesOnlyOurs() {
        #expect(KeyRemapping.removing(.capsLockToF18, from: [other, .capsLockToF18]) == [other])
        #expect(KeyRemapping.removing(.capsLockToF18, from: [escape]) == [escape])
    }
}
