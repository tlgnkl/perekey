// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

private let rightOption: UInt64 = EventFlags.option | ModifierKey.rightOption.eventFlagMask
private let leftOption = Keyboard.leftOption
private let optionSpace = VoiceTrigger.hold(keyCode: KeyCode.space, modifiers: [.option])

private extension Keyboard {
    /// The standard shortcuts, with dictation on this trigger.
    init(voice: VoiceTrigger?) {
        self.init(AppSettings().snapshot(voice: VoiceSettings(isEnabled: voice != nil, trigger: voice ?? .default)))
    }

    @discardableResult
    mutating func modifiers(_ key: ModifierKey, flags: UInt64, at location: PointerLocation? = nil) -> Output {
        time += 0.01
        return send(.flagsChanged(keyCode: key.keyCode, flags: flags, origin: .user, time: time, location: location))
    }

    @discardableResult
    mutating func key(_ phase: KeyEvent.Phase, _ keyCode: UInt16, flags: UInt64 = 0, isRepeat: Bool = false) -> Output {
        time += 0.03
        return send(.key(KeyEvent(phase, keyCode: keyCode, flags: flags, isRepeat: isRepeat), time: time))
    }

    /// Holds ⌥Space and checks that the hold began.
    mutating func beginOptionSpace() {
        time += 0.3
        modifiers(.leftOption, flags: Self.leftOption)
        let down = key(.down, KeyCode.space, flags: Self.leftOption)
        #expect(down.disposition == .drop)
        #expect(down.effects == [.voice(.holdBegan)])
    }
}

private extension Output {
    var voice: [VoiceSignal] {
        effects.compactMap { if case let .voice(signal) = $0 { signal } else { nil } }
    }
}

@Suite struct VoiceTapTests {
    @Test func rightOptionTapToggles() {
        var keyboard = Keyboard(voice: .default)
        keyboard.type("ghbdtn", in: Fixture.abc)
        let output = keyboard.tap(.rightOption, flags: rightOption)
        #expect(output.effects == [.voice(.toggle)], "no retype on the right Option key")
        #expect(keyboard.tap(.rightOption, flags: rightOption).effects == [.voice(.toggle)])
    }

    @Test func leftOptionStillRetypes() {
        var keyboard = Keyboard(voice: .default)
        keyboard.type("ghbdtn", in: Fixture.abc)
        let output = keyboard.tapOption()
        #expect(output.retype?.text == "привет")
        #expect(output.voice.isEmpty)
    }

    @Test func optionClickIsNoTap() {
        var keyboard = Keyboard(voice: .default)
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption)
        keyboard.time += 0.05
        keyboard.send(.click(time: keyboard.time))
        #expect(keyboard.modifiers(.rightOption, flags: 0).effects.isEmpty)
    }

    @Test func optionDragIsNoTap() {
        var keyboard = Keyboard(voice: .default)
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption, at: PointerLocation(x: 10, y: 10))
        keyboard.time += 0.02
        keyboard.send(.click(time: keyboard.time))
        keyboard.time += 0.02
        keyboard.send(.scroll(time: keyboard.time))
        #expect(keyboard.modifiers(.rightOption, flags: 0, at: PointerLocation(x: 80, y: 40)).effects.isEmpty)
    }

    @Test func optionWithPointerMovementIsNoTap() {
        var keyboard = Keyboard(voice: .default)
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption, at: PointerLocation(x: 500, y: 300))
        keyboard.time += 0.1
        #expect(keyboard.modifiers(.rightOption, flags: 0, at: PointerLocation(x: 512, y: 300)).effects.isEmpty)

        // A pointer that stayed put is a tap.
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption, at: PointerLocation(x: 512, y: 300))
        keyboard.time += 0.1
        #expect(keyboard.modifiers(.rightOption, flags: 0, at: PointerLocation(x: 512, y: 300)).effects
            == [.voice(.toggle)])

        // So is one nudged by a hand on the mouse, up to 3 points.
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption, at: PointerLocation(x: 512, y: 300))
        keyboard.time += 0.1
        #expect(keyboard.modifiers(.rightOption, flags: 0, at: PointerLocation(x: 514, y: 302)).effects
            == [.voice(.toggle)])
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption, at: PointerLocation(x: 512, y: 300))
        keyboard.time += 0.1
        #expect(keyboard.modifiers(.rightOption, flags: 0, at: PointerLocation(x: 515, y: 302)).effects.isEmpty)
    }

    @Test func longPressIsNoTap() {
        var keyboard = Keyboard(voice: .default)
        keyboard.time += 0.3
        keyboard.modifiers(.rightOption, flags: rightOption)
        keyboard.time += 0.6
        #expect(keyboard.modifiers(.rightOption, flags: 0).effects.isEmpty)
    }

    @Test func secureInputSilencesTheTap() {
        var keyboard = Keyboard(voice: .default)
        keyboard.send(.secureInputChanged(true))
        #expect(keyboard.tap(.rightOption, flags: rightOption).effects.isEmpty)
        keyboard.send(.secureInputChanged(false))
        #expect(keyboard.tap(.rightOption, flags: rightOption).effects == [.voice(.toggle)])
    }

    @Test func anotherTapChordLeavesOptionAlone() throws {
        var keyboard = Keyboard(voice: .tap(.rightCommand))
        keyboard.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(keyboard.tap(.rightOption, flags: rightOption).retype)
        #expect(retype.text == "привет")
        keyboard.completeRetype(retype)
        let rightCommand = EventFlags.command | ModifierKey.rightCommand.eventFlagMask
        #expect(keyboard.tap(.rightCommand, flags: rightCommand).effects == [.voice(.toggle)])
    }

    @Test func userShortcutOnTheSameKeysWins() {
        var settings = AppSettings()
        settings.apply(.separateKeys)
        var keyboard = Keyboard(settings.snapshot(voice: VoiceSettings(isEnabled: true)))
        let output = keyboard.tap(.rightOption, flags: rightOption)
        #expect(output.voice.isEmpty)
        #expect(output.effects == [.selectLayout(Fixture.russian.id)])
    }

    @Test func voiceOffKeepsEveryOptionRetyping() throws {
        #expect(AppSettings().snapshot(voice: VoiceSettings()) == AppSettings().snapshot)
        #expect(AppSettings().snapshot.voice == nil)
        // A trigger set up but off changes nothing either.
        let off = VoiceSettings(isEnabled: false, trigger: optionSpace)
        #expect(AppSettings().snapshot(voice: off) == AppSettings().snapshot)

        var keyboard = Keyboard(voice: nil)
        keyboard.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(keyboard.tap(.rightOption, flags: rightOption).retype)
        #expect(retype.text == "привет")
        keyboard.completeRetype(retype)
        keyboard.time += 0.3
        keyboard.modifiers(.leftOption, flags: leftOption)
        let space = keyboard.key(.down, KeyCode.space, flags: leftOption)
        #expect(space.disposition == .pass)
        #expect(space.voice.isEmpty)
    }
}

@Suite struct VoiceHoldTests {
    @Test func holdBeginsAndEndsOnKeyUp() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        let repeated = keyboard.key(.down, KeyCode.space, flags: leftOption, isRepeat: true)
        #expect(repeated.disposition == .drop)
        #expect(repeated.effects.isEmpty)
        let up = keyboard.key(.up, KeyCode.space, flags: leftOption)
        #expect(up.disposition == .drop)
        #expect(up.effects == [.voice(.holdEnded(reason: .released))])
        // The Option press was no tap: Space broke it.
        #expect(keyboard.modifiers(.leftOption, flags: 0).effects.isEmpty)
    }

    @Test func holdEndsWhenTheModifierComesUpFirst() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        #expect(keyboard.modifiers(.leftOption, flags: 0).effects == [.voice(.holdEnded(reason: .released))])
        // Space is still down: its repeats and its key up are swallowed, not typed.
        #expect(keyboard.key(.down, KeyCode.space, isRepeat: true).disposition == .drop)
        let up = keyboard.key(.up, KeyCode.space)
        #expect(up.disposition == .drop)
        #expect(up.effects.isEmpty)
    }

    @Test func holdOutlivesLostInput() {
        // The tap was disabled by timeout: the engine sends `.inputLost`,
        // which resets the shortcuts.
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        keyboard.send(.inputLost)
        #expect(keyboard.key(.down, KeyCode.space, flags: leftOption, isRepeat: true).disposition == .drop)
        #expect(keyboard.key(.up, KeyCode.space, flags: leftOption).effects
            == [.voice(.holdEnded(reason: .released))])
    }

    @Test func holdOutlivesSecureInput() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        // Under Secure Input key ups do not reach the tap; modifier changes do.
        keyboard.send(.secureInputChanged(true))
        #expect(keyboard.modifiers(.leftOption, flags: 0).effects == [.voice(.holdEnded(reason: .released))])
    }

    @Test func holdKeyUpEndsItUnderSecureInput() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        keyboard.send(.secureInputChanged(true))
        let up = keyboard.key(.up, KeyCode.space, flags: leftOption)
        #expect(up.disposition == .drop)
        #expect(up.effects == [.voice(.holdEnded(reason: .released))])
    }

    @Test func noHoldUnderSecureInput() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.send(.secureInputChanged(true))
        keyboard.modifiers(.leftOption, flags: leftOption)
        let down = keyboard.key(.down, KeyCode.space, flags: leftOption)
        #expect(down.disposition == .pass)
        #expect(down.effects.isEmpty)
        #expect(keyboard.key(.up, KeyCode.space, flags: leftOption).effects.isEmpty)
    }

    @Test func lostHoldEndsOnce() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        #expect(keyboard.send(.voiceHoldLost).effects == [.voice(.holdEnded(reason: .lost))])
        #expect(keyboard.send(.voiceHoldLost).effects.isEmpty)
        // Its key up, if it comes after all, ends nothing.
        #expect(keyboard.key(.up, KeyCode.space, flags: leftOption).effects.isEmpty)
        // And the next press is a new hold.
        keyboard.beginOptionSpace()
    }

    @Test func pressAfterALostKeyUpBeginsAgain() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        keyboard.send(.inputLost)
        // Space and Option came up while the tap was off; Option went up and down again.
        #expect(keyboard.modifiers(.leftOption, flags: 0).effects == [.voice(.holdEnded(reason: .released))])
        keyboard.beginOptionSpace()
    }

    @Test func bareKeyAfterLostKeyUpsEndsTheHoldAndTypes() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        // The tap was disabled by timeout; the key ups of Space and ⌥ were lost.
        keyboard.send(.inputLost)
        let space = keyboard.key(.down, KeyCode.space)
        #expect(space.disposition == .pass)
        #expect(space.effects == [.voice(.holdEnded(reason: .lost))])
        #expect(keyboard.key(.up, KeyCode.space).disposition == .pass)
    }

    @Test func swallowedKeyUpBreaksAChord() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        #expect(keyboard.modifiers(.leftOption, flags: 0).effects == [.voice(.holdEnded(reason: .released))])
        // ⇧ goes down while Space is still held, then Space comes up: ⇧ is no tap.
        keyboard.time += 0.3
        keyboard.modifiers(.leftShift, flags: Keyboard.leftShift)
        #expect(keyboard.key(.up, KeyCode.space).disposition == .drop)
        #expect(keyboard.modifiers(.leftShift, flags: 0).effects.isEmpty, "no layout switch")
    }

    @Test func turningVoiceOffEndsTheHold() {
        var keyboard = Keyboard(voice: optionSpace)
        keyboard.beginOptionSpace()
        #expect(keyboard.send(.settingsChanged(AppSettings().snapshot)).effects
            == [.voice(.holdEnded(reason: .lost))])
        // Unchanged settings do not.
        var again = Keyboard(voice: optionSpace)
        again.beginOptionSpace()
        let same = AppSettings().snapshot(voice: VoiceSettings(isEnabled: true, trigger: optionSpace))
        #expect(again.send(.settingsChanged(same)).effects.isEmpty)
    }

    @Test func otherModifiersDoNotStartAHold() {
        var keyboard = Keyboard(voice: optionSpace)
        let optionShift = leftOption | Keyboard.leftShift
        keyboard.modifiers(.leftOption, flags: optionShift)
        #expect(keyboard.key(.down, KeyCode.space, flags: optionShift).disposition == .pass)
        #expect(keyboard.key(.down, KeyCode.space).disposition == .pass)
    }
}

@Suite struct VoiceSettingsTests {
    @Test func rightOptionNarrowsTheRetypeInTheSnapshotOnly() {
        var settings = AppSettings()
        settings.setTrigger(.modifiers(.option, taps: .double), for: .changeCase)
        let snapshot = settings.snapshot(voice: VoiceSettings(isEnabled: true))
        #expect(snapshot.voice == .default)
        #expect(snapshot.hotkeys.contains(HotkeyBinding(.modifiers(.leftOption, taps: .single), action: .convertLastWord)))
        #expect(snapshot.hotkeys.contains(HotkeyBinding(.modifiers(.leftOption, taps: .double), action: .changeCase)))
        #expect(!snapshot.hotkeys.contains { $0.trigger == .modifiers(.option, taps: .single) })
        #expect(settings.trigger(for: .convertLastWord) == .modifiers(.option, taps: .single))
        #expect(AppSettings().preset == .standard)
    }

    @Test func narrowingKeepsF18() {
        let snapshot = AppSettings(capsLock: .instant).snapshot(voice: VoiceSettings(isEnabled: true))
        #expect(snapshot.hotkeys.contains(HotkeyBinding(.key(keyCode: KeyCode.f18, modifiers: []), action: .switchLayout)))
    }

    @Test func otherTriggersNarrowNothing() {
        let hotkeys = AppSettings().hotkeys
        #expect(VoiceTrigger.tap(.rightCommand).narrowing(hotkeys) == hotkeys)
        #expect(optionSpace.narrowing(hotkeys) == hotkeys)
        let separate = HotkeyPreset.separateKeys.hotkeys
        #expect(VoiceTrigger.default.narrowing(separate) == separate)
    }

    @Test func conflicts() {
        #expect(ShortcutConflicts.check(voice: .default, among: HotkeyPreset.standard.hotkeys).isEmpty)
        #expect(ShortcutConflicts.check(voice: .default, among: HotkeyPreset.separateKeys.hotkeys)
            == [.otherAction(.selectLanguage("ru"))])
        #expect(ShortcutConflicts.check(voice: .tap(.option), among: HotkeyPreset.standard.hotkeys)
            == [.otherAction(.convertLastWord)])
        var settings = AppSettings()
        settings.setTrigger(.key(keyCode: KeyCode.space, modifiers: [.option]), for: .pastePlain)
        #expect(ShortcutConflicts.check(voice: optionSpace, among: settings.hotkeys) == [.otherAction(.pastePlain)])
        #expect(ShortcutConflicts.check(voice: .hold(keyCode: KeyCode.space, modifiers: [.command]), among: [])
            == [.spotlight])
        #expect(ShortcutConflicts.check(voice: .tap(ModifierChord([.function: .either])), among: []) == [.globeKey])
    }

    @Test func decodingIsTolerant() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(VoiceSettings.self, from: Data("{}".utf8)) == VoiceSettings())
        #expect(try decoder.decode(VoiceSettings.self, from: Data(#"{"isEnabled":true}"#.utf8)).activeTrigger
            == .default, "a missing trigger is the default one")

        // A trigger of a later version: dictation stays off, it takes no key.
        let unknownTrigger = Data(#"{"isEnabled":true,"trigger":{"kind":"fnTwice"},"model":"x"}"#.utf8)
        var later = try decoder.decode(VoiceSettings.self, from: unknownTrigger)
        #expect(later.isEnabled)
        #expect(later.unreadableKeys == ["trigger"])
        #expect(later.activeTrigger == nil)
        #expect(AppSettings().snapshot(voice: later) == AppSettings().snapshot, "⌥ still retypes on both sides")
        // Until the user picks a trigger.
        later.trigger = .tap(.rightCommand)
        #expect(later.unreadableKeys.isEmpty)
        #expect(later.activeTrigger == .tap(.rightCommand))

        let wrongType = try decoder.decode(VoiceSettings.self, from: Data(#"{"isEnabled":"yes","trigger":7}"#.utf8))
        #expect(wrongType.unreadableKeys == ["isEnabled", "trigger"])
        #expect(wrongType.activeTrigger == nil)
    }

    @Test func unreadableKeysAreNotWritten() throws {
        let data = Data(#"{"isEnabled":true,"trigger":{"kind":"fnTwice"}}"#.utf8)
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(object["trigger"] == nil)
        #expect(object["isEnabled"] as? Bool == true)
    }

    @Test func newerSchemaKeepsDictationOff() throws {
        let data = Data(#"{"schemaVersion":2,"isEnabled":true,"trigger":{"kind":"tap","chord":{"requirements":["command","right"]}}}"#.utf8)
        let settings = try JSONDecoder().decode(VoiceSettings.self, from: data)
        #expect(settings.isEnabled)
        #expect(settings.trigger == .tap(.rightCommand))
        #expect(settings.newerSchemaVersion == 2)
        #expect(settings.activeTrigger == nil)
        let current = Data(#"{"schemaVersion":1,"isEnabled":true}"#.utf8)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: current).activeTrigger == .default)
    }

    @Test func roundTrip() throws {
        for trigger in [VoiceTrigger.default, .tap(.rightCommand), optionSpace,
                        .hold(keyCode: 3, modifiers: [.control, .option, .command])]
        {
            let settings = VoiceSettings(isEnabled: true, trigger: trigger)
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(VoiceSettings.self, from: data) == settings)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["schemaVersion"] as? Int == VoiceSettings.schemaVersion)
        }
    }
}

@Suite struct VoiceSessionTests {
    @Test func escCancelsOnlyDuringASession() {
        var keyboard = Keyboard(voice: .default)
        let before = keyboard.key(.down, KeyCode.escape)
        #expect(before.disposition == .pass)
        #expect(before.voice.isEmpty)
        #expect(keyboard.key(.up, KeyCode.escape).disposition == .pass)

        keyboard.send(.voiceSession(true))
        let down = keyboard.key(.down, KeyCode.escape)
        #expect(down.disposition == .drop)
        #expect(down.effects == [.voice(.cancel)])
        #expect(keyboard.key(.up, KeyCode.escape).disposition == .drop, "its key up goes with it")

        keyboard.send(.voiceSession(false))
        #expect(keyboard.key(.down, KeyCode.escape).disposition == .pass)
    }

    @Test func otherKeysPassDuringASession() {
        var keyboard = Keyboard(voice: .default)
        keyboard.send(.voiceSession(true))
        keyboard.type("ghbdtn", in: Fixture.abc)
        #expect(keyboard.key(.down, KeyCode.space).voice.isEmpty)
    }
}
