// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct ModifierFlagsTests {
    @Test func deviceBitsMapToKeys() {
        // Device-independent masks (0x20000 shift, 0x100000 command, …) and
        // kCGEventFlagMaskNonCoalesced (0x100) must not affect the result.
        #expect(ModifierKey.pressed(inEventFlags: 0x0002_0002) == [.leftShift])
        #expect(ModifierKey.pressed(inEventFlags: 0x0010_0010) == [.rightCommand])
        #expect(ModifierKey.pressed(inEventFlags: 0x000A_0024) == [.leftOption, .rightShift])
        #expect(ModifierKey.pressed(inEventFlags: 0x0004_2000) == [.rightControl])
        #expect(ModifierKey.pressed(inEventFlags: 0x0080_0000) == [.function])
        #expect(ModifierKey.pressed(inEventFlags: 0x0000_0100).isEmpty)
    }

    @Test func keyCodesRoundTrip() {
        for key in ModifierKey.allCases {
            #expect(ModifierKey(keyCode: key.keyCode) == key)
        }
        #expect(ModifierKey(keyCode: 57) == nil) // Caps Lock
        #expect(ModifierKey(keyCode: 0) == nil) // A
    }

    @Test func masksAreDistinct() {
        let masks = ModifierKey.allCases.map(\.eventFlagMask)
        #expect(Set(masks).count == masks.count)
    }
}

@Suite struct HotkeyPresetTests {
    /// Every combination of held modifiers.
    private static let allKeySets: [Set<ModifierKey>] = {
        let keys = ModifierKey.allCases
        return (0..<(1 << keys.count)).map { bits in
            Set(keys.indices.filter { bits & (1 << $0) != 0 }.map { keys[$0] })
        }
    }()

    @Test(arguments: HotkeyPreset.allCases)
    func bindingsAreUnambiguous(preset: HotkeyPreset) {
        for keys in Self.allKeySets {
            for taps in [1, 2] {
                let matching = preset.bindings.filter { $0.taps == taps && $0.chord.matches(keys) }
                #expect(matching.count <= 1, "\(preset): \(keys) matches \(matching.map(\.action))")
            }
        }
    }

    @Test func defaultIsShiftAndOption() {
        var d = ChordDetector(bindings: HotkeyPreset.default.bindings)
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        #expect(d.modifiersChanged(to: [], at: 0.1) == .switchLayout)
        _ = d.modifiersChanged(to: [.rightOption], at: 1)
        #expect(d.modifiersChanged(to: [], at: 1.1) == .convertLastWord)
    }

    @Test func doubleShiftFiresSingleThenDouble() {
        // The first tap switches the layout at once; the second retypes the word.
        // Retyping must select the word's target layout, not toggle again.
        var d = ChordDetector(bindings: HotkeyPreset.doubleShift.bindings)
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        #expect(d.modifiersChanged(to: [], at: 0.1) == .switchLayout)
        _ = d.modifiersChanged(to: [.leftShift], at: 0.2)
        #expect(d.modifiersChanged(to: [], at: 0.3) == .convertLastWord)
    }

    @Test func altShiftIsNotOption() {
        var d = ChordDetector(bindings: HotkeyPreset.windowsAltShift.bindings)
        _ = d.modifiersChanged(to: [.leftOption], at: 0)
        _ = d.modifiersChanged(to: [.leftOption, .leftShift], at: 0.05)
        _ = d.modifiersChanged(to: [.leftShift], at: 0.1)
        #expect(d.modifiersChanged(to: [], at: 0.15) == .switchLayout)
    }

    @Test func separateKeysSelectLanguages() {
        var d = ChordDetector(bindings: HotkeyPreset.separateKeys.bindings)
        _ = d.modifiersChanged(to: [.rightCommand], at: 0)
        #expect(d.modifiersChanged(to: [], at: 0.1) == .selectLanguage("en"))
        _ = d.modifiersChanged(to: [.rightOption], at: 1)
        #expect(d.modifiersChanged(to: [], at: 1.1) == .selectLanguage("ru"))
        _ = d.modifiersChanged(to: [.leftOption], at: 2)
        #expect(d.modifiersChanged(to: [], at: 2.1) == .convertLastWord)
    }
}
