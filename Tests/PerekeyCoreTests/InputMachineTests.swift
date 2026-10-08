// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

@Suite struct ManualRetypeTests {
    @Test func optionRetypesLastWord() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let output = kb.tapOption()
        #expect(output.effects.first == .selectLayout(ru))
        let retype = try #require(output.retype)
        #expect(retype.deleteCount == 6)
        #expect(retype.text == "привет")
        #expect(retype.expected == "ghbdtn")
        #expect(retype.target == ru)
        #expect(retype.keys.map(\.stroke) == Fixture.abc.strokes("ghbdtn"))
    }

    @Test func russianPunctuationKeysAreLetters() throws {
        var kb = Keyboard()
        kb.type(",eltn", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).text == "будет")
    }

    @Test func capitalLetters() throws {
        var kb = Keyboard()
        kb.type("Ghbdtn", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).text == "Привет")
    }

    @Test func russianToEnglish() throws {
        var kb = Keyboard(current: ru)
        kb.type("руддщ", in: Fixture.russian)
        let output = kb.tapOption()
        #expect(output.effects.first == .selectLayout(en))
        #expect(try #require(output.retype).text == "hello")
    }

    @Test func spacesAfterWordAreRetypedToo() throws {
        var kb = Keyboard()
        kb.type("ghbdtn ", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.deleteCount == 7)
        #expect(retype.text == "привет ")
    }

    @Test func onlyTheLastWord() throws {
        var kb = Keyboard()
        kb.type("ghbdtn vbh", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).text == "мир")
    }

    @Test func secondOptionBringsWordBack() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let first = try #require(kb.tapOption().retype)
        #expect(kb.completeRetype(first) == [.releaseHeld])

        let output = kb.tapOption()
        #expect(output.effects.first == .selectLayout(en))
        let second = try #require(output.retype)
        #expect(second.text == "ghbdtn")
        #expect(second.expected == "привет")
        #expect(second.seq != first.seq)
    }

    @Test func backspaceEditsTheWord() throws {
        var kb = Keyboard()
        kb.type("ghbdtnn", in: Fixture.abc)
        kb.press(KeyCode.delete)
        #expect(try #require(kb.tapOption().retype).text == "привет")
    }

    @Test(arguments: [KeyCode.leftArrow, KeyCode.return, KeyCode.tab, KeyCode.escape, KeyCode.forwardDelete])
    func navigationForgetsWord(keyCode: UInt16) {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.press(keyCode)
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func commandShortcutForgetsWord() {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.press(0, flags: Keyboard.leftCommand) // ⌘A
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func optionBackspaceForgetsWord() {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.press(KeyCode.delete, flags: Keyboard.leftOption)
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func clickForgetsWordScrollDoesNot() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.send(.scroll(time: kb.time))
        #expect(try #require(kb.tapOption().retype).text == "привет")

        kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.send(.click(time: kb.time))
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func focusChangeForgetsWord() {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.send(.focusChanged(Focus(bundleID: "com.apple.Safari")))
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func wordTypedWithOptionIsRefused() {
        var kb = Keyboard()
        kb.type("ab", in: Fixture.abc)
        kb.press(5, flags: Keyboard.leftOption) // ⌥G types ©
        #expect(kb.tapOption().effects == [.refused(.unconvertibleWord)])
    }

    @Test func deadKeyAbandonsWord() throws {
        var kb = Keyboard()
        kb.type("caf", in: Fixture.abc)
        kb.press(14, flags: Keyboard.leftOption) // ⌥E: dead acute
        kb.press(14) // é
        kb.press(KeyCode.delete)
        let selection = kb.tapOption()
        #expect(selection.startsSelectionConversion)
        kb.send(.selectionRead(seq: try #require(selection.selectionSeq), text: ""))
        kb.type(" vbh", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).text == "мир")
    }

    @Test func passwordFieldIsRefused() {
        var kb = Keyboard()
        kb.send(.focusChanged(Focus(bundleID: "com.apple.Safari", isSecureField: true)))
        kb.type("ghbdtn", in: Fixture.abc)
        #expect(kb.tapOption().effects == [.refused(.secureField)])
    }

    @Test func inputMethodIsNotRetyped() {
        var kb = Keyboard()
        kb.send(.layoutChanged("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"))
        kb.type("ghbdtn", in: Fixture.abc)
        #expect(kb.tapOption().retype == nil)
    }

    @Test func ownEventsDoNotEnterBuffer() {
        var kb = Keyboard()
        for keyCode in Fixture.abc.strokes("ghbdtn").map(\.keyCode) {
            kb.press(keyCode, origin: .own(seq: 7, last: false))
        }
        #expect(kb.machine.buffer.isEmpty)
    }
}

@Suite struct FenceTests {
    @Test func holdsUserInputUntilRetypeArrives() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(kb.machine.isHolding)
        #expect(kb.press(9).disposition == .hold) // "v"
        #expect(kb.modifiers(keyCode: 56, flags: Keyboard.leftShift).disposition == .hold)
        #expect(kb.modifiers(keyCode: 56, flags: 0).disposition == .hold)

        #expect(kb.completeRetype(retype, confirm: false).isEmpty)
        #expect(kb.machine.isHolding, "the layout switch has not reached the app yet")
        #expect(kb.send(.layoutChanged(ru)).effects == [.releaseHeld])
        #expect(!kb.machine.isHolding)
    }

    @Test func replayedInputLandsInBuffer() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        kb.completeRetype(retype)
        for stroke in Fixture.russian.strokes(" мир") {
            #expect(kb.press(stroke.keyCode, origin: .replayed).disposition == .pass)
        }
        #expect(Fixture.russian.type(kb.machine.buffer.entries.map(\.stroke)) == "мир")
    }

    @Test func timeoutReleases() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let output = kb.tapOption()
        let deadline = try #require(output.effects.lazy.compactMap {
            if case let .scheduleDeadline(at) = $0 { at } else { nil }
        }.first)
        #expect(kb.send(.deadline(time: deadline - 0.01)).effects.isEmpty)
        #expect(kb.send(.deadline(time: deadline)).effects == [.releaseHeld])
    }

    @Test func lateKeyReleasesWithoutTimerAndKeepsOrder() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.tapOption()
        #expect(kb.press(9).disposition == .hold)
        kb.time += 3
        // The late key must not overtake the one held before it.
        #expect(kb.press(11) == Output(.hold, [.releaseHeld]))
        #expect(!kb.machine.isHolding)
    }

    @Test func fenceTimeoutCountsFromPosting() throws {
        // The main thread may take a while to select the layout. The 0.3 s
        // must not run out before the retype is even posted.
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(kb.send(.deadline(time: kb.time + 0.5)).effects.isEmpty, "not posted yet: still holding")
        #expect(kb.machine.pendingRetypeSeq == retype.seq)
        let postedAt = kb.time + 0.6
        let posted = kb.send(.retypePosted(seq: retype.seq, time: postedAt))
        #expect(posted.effects == [.scheduleDeadline(at: postedAt + 0.3)])
        #expect(kb.send(.deadline(time: postedAt + 0.3)).effects == [.releaseHeld])
        #expect(kb.machine.pendingRetypeSeq == nil, "a late post must now be dropped")
    }

    @Test func inputLostReleases() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        kb.tapOption()
        #expect(kb.send(.inputLost).effects == [.releaseHeld])
        #expect(kb.machine.buffer.isEmpty)
    }

    @Test func replayedInputIsHeldBehindNextRetype() throws {
        // ⌥ and "a" were held during the first retype. The replayed ⌥ starts a
        // second retype; the replayed "a" must wait for it, or its Backspaces
        // would erase "a" instead of the word.
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let first = try #require(kb.tapOption().retype)
        kb.completeRetype(first)
        kb.time += 0.3
        kb.modifiers(keyCode: 58, flags: Keyboard.leftOption, origin: .replayed)
        let second = try #require(kb.modifiers(keyCode: 58, flags: 0, origin: .replayed).retype)
        #expect(second.text == "ghbdtn")
        #expect(kb.press(0, origin: .replayed).disposition == .hold)
        #expect(kb.completeRetype(second) == [.releaseHeld])
    }

    @Test func cancelledRetypeRestoresLayout() throws {
        var kb = Keyboard()
        kb.type("ghbdtn", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(kb.send(.retypeCancelled(seq: retype.seq + 1)).effects.isEmpty, "another retype")
        #expect(kb.send(.retypeCancelled(seq: retype.seq)).effects == [.selectLayout(en), .releaseHeld])
        #expect(kb.machine.buffer.isEmpty)
        #expect(kb.machine.currentLayout == en)
    }

    @Test func noWaitWhenLayoutAlreadySelected() throws {
        // Double Shift: the first tap selects Russian and the system confirms it
        // before the second tap retypes.
        var kb = Keyboard(Settings(hotkeys: HotkeyPreset.doubleShift.hotkeys))
        kb.type("ghbdtn", in: Fixture.abc)
        #expect(kb.tapShift().effects == [.selectLayout(ru)])
        kb.send(.layoutChanged(ru))
        kb.time -= 0.2 // the second tap comes quickly
        let output = kb.tapShift()
        let retype = try #require(output.retype)
        #expect(!output.effects.contains(.selectLayout(ru)))
        #expect(retype.text == "привет")
        #expect(kb.completeRetype(retype, confirm: false) == [.releaseHeld])
    }

    @Test func waitsForUnconfirmedLayout() throws {
        // Double Shift again, but the first switch has not been confirmed yet.
        var kb = Keyboard(Settings(hotkeys: HotkeyPreset.doubleShift.hotkeys))
        kb.type("ghbdtn", in: Fixture.abc)
        kb.tapShift()
        kb.time -= 0.2
        let retype = try #require(kb.tapShift().retype)
        #expect(kb.completeRetype(retype, confirm: false).isEmpty)
        #expect(kb.send(.layoutChanged(ru)).effects == [.releaseHeld])
    }
}

@Suite struct ShortcutTests {
    @Test func shiftCyclesLayouts() {
        var kb = Keyboard(layouts: [Fixture.abc, Fixture.russian, Fixture.ukrainianPC])
        #expect(kb.tapShift().effects == [.selectLayout(ru)])
        #expect(kb.tapShift().effects == [.selectLayout(Fixture.ukrainianPC.id)])
        #expect(kb.tapShift().effects == [.selectLayout(en)])
    }

    @Test func shiftWhileTypingIsNotAShortcut() {
        var kb = Keyboard()
        kb.type("Hello", in: Fixture.abc)
        #expect(kb.machine.currentLayout == en)
    }

    @Test func lateConfirmationDoesNotUndoLaterSwitch() {
        var kb = Keyboard(layouts: [Fixture.abc, Fixture.russian, Fixture.ukrainianPC])
        kb.tapShift()
        kb.tapShift()
        #expect(kb.machine.currentLayout == Fixture.ukrainianPC.id)
        kb.send(.layoutChanged(ru)) // the first switch, confirmed late
        #expect(kb.machine.currentLayout == Fixture.ukrainianPC.id)
        kb.send(.layoutChanged(Fixture.ukrainianPC.id))
        kb.send(.layoutChanged(en)) // now the user picks English from the menu
        #expect(kb.machine.currentLayout == en)
    }

    @Test func externalSwitchIsFollowed() {
        var kb = Keyboard()
        kb.send(.layoutChanged(ru))
        #expect(kb.tapShift().effects == [.selectLayout(en)])
    }

    @Test func bothShiftsToggleAutoswitch() {
        var kb = Keyboard()
        kb.time += 0.3
        kb.modifiers(keyCode: 56, flags: Keyboard.leftShift)
        kb.modifiers(keyCode: 60, flags: Keyboard.leftShift | Keyboard.rightShift)
        kb.modifiers(keyCode: 56, flags: Keyboard.rightShift)
        #expect(kb.modifiers(keyCode: 60, flags: 0).effects == [.autoswitchChanged(false)])
    }

    @Test func separateKeysSelectByLanguage() {
        var kb = Keyboard(Settings(hotkeys: HotkeyPreset.separateKeys.hotkeys))
        let rightOption = EventFlags.option | ModifierKey.rightOption.eventFlagMask
        let rightCommand = EventFlags.command | ModifierKey.rightCommand.eventFlagMask
        #expect(kb.tap(.rightOption, flags: rightOption).effects == [.selectLayout(ru)])
        #expect(kb.tap(.rightCommand, flags: rightCommand).effects == [.selectLayout(en)])
        #expect(kb.tap(.rightCommand, flags: rightCommand).effects.isEmpty, "already English")
    }

    @Test func keyTriggerIsSwallowed() {
        let f18: UInt16 = 79
        var kb = Keyboard(Settings(hotkeys: [HotkeyBinding(.key(keyCode: f18, modifiers: []), action: .switchLayout)]))
        kb.time += 1
        let down = kb.send(.key(KeyEvent(.down, keyCode: f18), time: kb.time))
        #expect(down == Output(.drop, [.selectLayout(ru)]))
        let up = kb.send(.key(KeyEvent(.up, keyCode: f18), time: kb.time + 0.05))
        #expect(up.disposition == .drop)
    }

    @Test func keyTriggerIgnoresFunctionBit() {
        // F-keys always carry the fn bit in their flags.
        let f18: UInt16 = 79
        var kb = Keyboard(Settings(hotkeys: [HotkeyBinding(.key(keyCode: f18, modifiers: []), action: .switchLayout)]))
        kb.time += 1
        let down = kb.send(.key(KeyEvent(.down, keyCode: f18, flags: EventFlags.function), time: kb.time))
        #expect(down == Output(.drop, [.selectLayout(ru)]))
    }

    @Test func secureInputForgetsSwallowedKeyUps() {
        let a: UInt16 = 0
        var kb = Keyboard(Settings(hotkeys: [HotkeyBinding(.key(keyCode: a, modifiers: [.control]), action: .switchLayout)]))
        kb.time += 1
        kb.send(.key(KeyEvent(.down, keyCode: a, flags: EventFlags.control), time: kb.time))
        kb.send(.secureInputChanged(true)) // ⌃A's key up never reaches the tap
        kb.send(.secureInputChanged(false))
        #expect(kb.press(a).disposition == .pass)
        kb.time += 0.1
        #expect(kb.send(.key(KeyEvent(.up, keyCode: a), time: kb.time)).disposition == .pass)
    }

    @Test func secureInputDisablesChords() {
        var kb = Keyboard()
        kb.send(.secureInputChanged(true))
        #expect(kb.tapShift().effects.isEmpty)
        kb.send(.secureInputChanged(false))
        #expect(kb.tapShift().effects == [.selectLayout(ru)])
    }

    @Test func settingsChangeRebindsShortcuts() {
        var kb = Keyboard()
        kb.send(.settingsChanged(Settings(hotkeys: HotkeyPreset.windowsAltShift.hotkeys)))
        #expect(kb.tapShift().effects.isEmpty)
    }

    @Test func modifiersWithoutSideBits() {
        // Virtual keyboards may set only the device-independent bits.
        #expect(InputMachine.modifiers(keyCode: 61, flags: EventFlags.option) == [.rightOption])
        #expect(InputMachine.modifiers(keyCode: 61, flags: EventFlags.option | EventFlags.shift)
            == [.rightOption, .leftShift])
        #expect(InputMachine.modifiers(keyCode: 61, flags: 0).isEmpty)
    }
}
