// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private enum Action: Hashable, Sendable {
    case switchLayout, convertWord, toggleAutoswitch, english
}

private func detector() -> ChordDetector<Action> {
    ChordDetector(bindings: [
        .init(.shift, action: .switchLayout),
        .init(.shift, taps: 2, action: .convertWord),
        .init(.bothShifts, action: .toggleAutoswitch),
        .init(.rightCommand, action: .english),
    ])
}

@Suite struct ModifierChordTests {
    @Test func eitherSideMatchesOneKey() {
        #expect(ModifierChord.shift.matches([.leftShift]))
        #expect(ModifierChord.shift.matches([.rightShift]))
        #expect(!ModifierChord.shift.matches([.leftShift, .rightShift]))
    }

    @Test func extraModifierBreaksMatch() {
        #expect(!ModifierChord.shift.matches([.leftShift, .leftCommand]))
        #expect(ModifierChord.optionShift.matches([.leftOption, .rightShift]))
        #expect(!ModifierChord.optionShift.matches([.leftOption, .rightShift, .leftControl]))
    }

    @Test func sideSpecificChord() {
        #expect(ModifierChord.rightCommand.matches([.rightCommand]))
        #expect(!ModifierChord.rightCommand.matches([.leftCommand]))
    }
}

@Suite struct ChordDetectorTests {
    @Test func singleTapFiresOnRelease() {
        var d = detector()
        #expect(d.modifiersChanged(to: [.leftShift], at: 0) == nil)
        #expect(d.modifiersChanged(to: [], at: 0.1) == .switchLayout)
    }

    @Test func doubleTapFiresSecondAction() {
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        #expect(d.modifiersChanged(to: [], at: 0.1) == .switchLayout)
        _ = d.modifiersChanged(to: [.leftShift], at: 0.2)
        #expect(d.modifiersChanged(to: [], at: 0.3) == .convertWord)
    }

    @Test func tripleTapDoesNotFireDoubleTwice() {
        var d = detector()
        for t in [0.0, 0.2] {
            _ = d.modifiersChanged(to: [.leftShift], at: t)
            _ = d.modifiersChanged(to: [], at: t + 0.05)
        }
        _ = d.modifiersChanged(to: [.leftShift], at: 0.4)
        #expect(d.modifiersChanged(to: [], at: 0.45) == .switchLayout)
    }

    @Test func slowSecondTapIsSingle() {
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        _ = d.modifiersChanged(to: [], at: 0.1)
        _ = d.modifiersChanged(to: [.leftShift], at: 1.0)
        #expect(d.modifiersChanged(to: [], at: 1.1) == .switchLayout)
    }

    @Test func typingWhileHeldCancels() {
        // Shift+A types a capital letter and must not switch the layout.
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        d.otherInput(at: 0.05)
        #expect(d.modifiersChanged(to: [], at: 0.1) == nil)
    }

    @Test func typingBetweenTapsBreaksDoubleTap() {
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        _ = d.modifiersChanged(to: [], at: 0.05)
        d.otherInput(at: 0.06)
        _ = d.modifiersChanged(to: [.leftShift], at: 0.3)
        #expect(d.modifiersChanged(to: [], at: 0.35) == .switchLayout)
    }

    @Test func longHoldCancels() {
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        #expect(d.modifiersChanged(to: [], at: 2) == nil)
    }

    @Test func chordUsesPeakSet() {
        // Left Shift down, right Shift down, released one by one.
        var d = detector()
        _ = d.modifiersChanged(to: [.leftShift], at: 0)
        _ = d.modifiersChanged(to: [.leftShift, .rightShift], at: 0.05)
        _ = d.modifiersChanged(to: [.rightShift], at: 0.1)
        #expect(d.modifiersChanged(to: [], at: 0.15) == .toggleAutoswitch)
    }

    @Test func commandShiftFourIsNotAChord() {
        var d = ChordDetector<Action>(bindings: [.init(.commandShift, action: .switchLayout)])
        _ = d.modifiersChanged(to: [.leftCommand], at: 0)
        _ = d.modifiersChanged(to: [.leftCommand, .leftShift], at: 0.05)
        d.otherInput(at: 0.1) // the "4" key
        _ = d.modifiersChanged(to: [.leftCommand], at: 0.2)
        #expect(d.modifiersChanged(to: [], at: 0.25) == nil)
    }

    @Test func shiftRightAfterTypingIsIgnored() {
        var d = detector()
        d.otherInput(at: 1.0)
        _ = d.modifiersChanged(to: [.leftShift], at: 1.05)
        #expect(d.modifiersChanged(to: [], at: 1.1) == nil)
    }

    @Test func shiftAfterPauseWorks() {
        var d = detector()
        d.otherInput(at: 1.0)
        _ = d.modifiersChanged(to: [.leftShift], at: 1.2)
        #expect(d.modifiersChanged(to: [], at: 1.25) == .switchLayout)
    }

    @Test func rightCommandOnly() {
        var d = detector()
        _ = d.modifiersChanged(to: [.leftCommand], at: 0)
        #expect(d.modifiersChanged(to: [], at: 0.1) == nil)
        _ = d.modifiersChanged(to: [.rightCommand], at: 1)
        #expect(d.modifiersChanged(to: [], at: 1.1) == .english)
    }
}
