// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct ShortcutRecorderTests {
    @Test func optionShiftOnRelease() {
        var r = ShortcutRecorder()
        #expect(r.modifiersChanged(to: [.leftOption], at: 0) == nil)
        #expect(r.modifiersChanged(to: [.leftOption, .leftShift], at: 0.05) == nil)
        #expect(r.held == [.leftOption, .leftShift])
        #expect(r.modifiersChanged(to: [.leftShift], at: 0.1) == nil)
        #expect(r.modifiersChanged(to: [], at: 0.15) == nil, "waits for a possible second tap")
        #expect(r.deadline == 0.55)
        #expect(r.deadlinePassed(at: 0.5) == nil)
        #expect(r.deadlinePassed(at: 0.55) == .recorded(.modifiers(.optionShift, taps: .single)))
    }

    @Test func shiftTwice() {
        var r = ShortcutRecorder()
        _ = r.modifiersChanged(to: [.leftShift], at: 0)
        _ = r.modifiersChanged(to: [], at: 0.1)
        _ = r.modifiersChanged(to: [.leftShift], at: 0.2)
        #expect(r.modifiersChanged(to: [], at: 0.3) == .recorded(.modifiers(.shift, taps: .double)))
        #expect(r.deadline == nil)
    }

    @Test func differentSecondTapReplacesFirst() {
        var r = ShortcutRecorder()
        _ = r.modifiersChanged(to: [.leftShift], at: 0)
        _ = r.modifiersChanged(to: [], at: 0.1)
        _ = r.modifiersChanged(to: [.leftCommand], at: 0.2)
        #expect(r.modifiersChanged(to: [], at: 0.3) == nil)
        #expect(r.deadlinePassed(at: 0.7) == .recorded(.modifiers(ModifierChord([.command: .either]), taps: .single)))
    }

    @Test func bothShifts() {
        var r = ShortcutRecorder()
        _ = r.modifiersChanged(to: [.leftShift], at: 0)
        _ = r.modifiersChanged(to: [.leftShift, .rightShift], at: 0.05)
        _ = r.modifiersChanged(to: [], at: 0.1)
        #expect(r.deadlinePassed(at: 1) == .recorded(.modifiers(.bothShifts, taps: .single)))
    }

    @Test func sideIsKeptWhenAnotherActionUsesASide() {
        var r = ShortcutRecorder(otherBindings: HotkeyPreset.separateKeys.hotkeys)
        _ = r.modifiersChanged(to: [.leftCommand], at: 0)
        _ = r.modifiersChanged(to: [], at: 0.1)
        #expect(r.deadlinePassed(at: 1) == .recorded(.modifiers(ModifierChord([.command: .left]), taps: .single)))

        var plain = ShortcutRecorder(otherBindings: HotkeyPreset.standard.hotkeys)
        _ = plain.modifiersChanged(to: [.rightCommand], at: 0)
        _ = plain.modifiersChanged(to: [], at: 0.1)
        #expect(plain.deadlinePassed(at: 1) == .recorded(.modifiers(ModifierChord([.command: .either]), taps: .single)))
    }

    @Test func keyWithModifiers() {
        var r = ShortcutRecorder()
        _ = r.modifiersChanged(to: [.leftControl], at: 0)
        _ = r.modifiersChanged(to: [.leftControl, .leftOption], at: 0.05)
        let flags = EventFlags.control | EventFlags.option
        #expect(r.keyDown(keyCode: 14, flags: flags, at: 0.1) == .recorded(.key(keyCode: 14, modifiers: [.control, .option])))
        // Releasing the modifiers afterwards records nothing more.
        #expect(r.modifiersChanged(to: [], at: 0.2) == nil)
        #expect(r.deadline == nil)
    }

    @Test func plainLetterNeedsModifier() {
        var r = ShortcutRecorder()
        #expect(r.keyDown(keyCode: 0, flags: 0, at: 0) == .needsModifier)
    }

    @Test func functionKeyAlone() {
        var r = ShortcutRecorder()
        #expect(r.keyDown(keyCode: KeyCode.f18, flags: EventFlags.function, at: 0)
            == .recorded(.key(keyCode: KeyCode.f18, modifiers: [])))
    }

    @Test func escapeAndDelete() {
        var r = ShortcutRecorder()
        #expect(r.keyDown(keyCode: KeyCode.escape, flags: 0, at: 0) == .cancelled)
        #expect(r.keyDown(keyCode: KeyCode.delete, flags: 0, at: 0) == .cleared)
    }

    @Test func pendingTapIsDroppedByKey() {
        var r = ShortcutRecorder()
        _ = r.modifiersChanged(to: [.leftShift], at: 0)
        _ = r.modifiersChanged(to: [], at: 0.1)
        #expect(r.keyDown(keyCode: KeyCode.escape, flags: 0, at: 0.2) == .cancelled)
        #expect(r.deadlinePassed(at: 1) == nil)
    }
}

@Suite struct ShortcutConflictTests {
    private let standard = HotkeyPreset.standard.hotkeys

    @Test func systemShortcuts() {
        #expect(ShortcutConflicts.check(.key(keyCode: KeyCode.space, modifiers: [.command]),
                                        for: .switchLayout, among: []) == [.spotlight])
        #expect(ShortcutConflicts.check(.key(keyCode: KeyCode.space, modifiers: [.control]),
                                        for: .switchLayout, among: []) == [.systemInputSwitch])
        #expect(ShortcutConflicts.check(.modifiers(ModifierChord([.function: .either]), taps: .single),
                                        for: .switchLayout, among: []) == [.globeKey])
        #expect(ShortcutConflicts.check(.modifiers(ModifierChord([.function: .either]), taps: .double),
                                        for: .switchLayout, among: []) == [.dictation])
    }

    @Test func shiftTwiceWarnsAboutJetBrains() {
        let conflicts = ShortcutConflicts.check(.modifiers(.shift, taps: .double), for: .convertLastWord,
                                                among: standard)
        #expect(conflicts.contains(.jetBrainsSearch))
    }

    @Test func overlapWithAnotherAction() {
        // Option for switching would also retype.
        #expect(ShortcutConflicts.check(.modifiers(.option, taps: .single), for: .switchLayout, among: standard)
            == [.otherAction(.convertLastWord)])
        // Left Option overlaps Option-either too.
        #expect(ShortcutConflicts.check(.modifiers(.leftOption, taps: .single), for: .switchLayout,
                                        among: standard) == [.otherAction(.convertLastWord)])
        // Right ⌥ does not overlap left ⌥.
        #expect(ShortcutConflicts.check(.modifiers(.rightOption, taps: .single), for: .switchLayout,
                                        among: HotkeyPreset.separateKeys.hotkeys)
            == [.otherAction(.selectLanguage("ru"))])
    }

    @Test func replacingOwnShortcutIsNoConflict() {
        #expect(ShortcutConflicts.check(.modifiers(.shift, taps: .single), for: .switchLayout, among: standard).isEmpty)
    }

    @Test(arguments: HotkeyPreset.allCases)
    func presetsHaveNoInternalConflicts(preset: HotkeyPreset) {
        for binding in preset.hotkeys {
            let conflicts = ShortcutConflicts.check(binding.trigger, for: binding.action, among: preset.hotkeys)
            #expect(!conflicts.contains { if case .otherAction = $0 { true } else { false } }, "\(preset) \(binding)")
        }
    }

    @Test func presetRecognized() {
        #expect(HotkeyPreset(matching: HotkeyPreset.doubleShift.hotkeys.reversed()) == .doubleShift)
        #expect(HotkeyPreset(matching: []) == nil)
    }
}
