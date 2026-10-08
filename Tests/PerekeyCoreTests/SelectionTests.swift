// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

extension Output {
    /// The `seq` of a selection conversion this output starts.
    var selectionSeq: UInt32? {
        effects.lazy.compactMap { if case let .convertSelection(seq) = $0 { seq } else { nil } }.first
    }

    /// Starts a selection conversion and does nothing else but set its deadline.
    var startsSelectionConversion: Bool {
        selectionSeq != nil && effects.count == 2
            && effects.contains { if case .scheduleDeadline = $0 { true } else { false } }
    }
}

@Suite struct SelectionFenceTests {
    @Test func shortcutWithoutWordStartsFence() throws {
        var kb = Keyboard()
        let output = kb.tapOption()
        #expect(output.startsSelectionConversion)
        #expect(kb.machine.isHolding)
        #expect(kb.machine.pendingRetypeSeq == output.selectionSeq)
        #expect(kb.press(0).disposition == .hold)
    }

    @Test func selectionIsRetypedAndHeldInputReplayedAfter() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.press(0).disposition == .hold, "typed while the selection is read")

        let output = kb.send(.selectionRead(seq: seq, text: "Ghbdtn vbh!"))
        #expect(output.effects.first == .selectLayout(ru))
        let retype = try #require(output.retype)
        #expect(retype.seq == seq)
        #expect(retype.deleteCount == 0)
        #expect(retype.text == "Привет мир!")
        #expect(retype.expected == "Ghbdtn vbh!")
        #expect(retype.target == ru)
        #expect(!retype.viaAccessibility)
        #expect(kb.machine.isHolding)
        #expect(kb.press(1).disposition == .hold, "typed while the retype is posted")

        #expect(kb.completeRetype(retype) == [.releaseHeld])
        #expect(!kb.machine.isHolding)
        #expect(kb.machine.currentLayout == ru)
    }

    @Test func russianSelectionGoesToEnglish() throws {
        var kb = Keyboard(current: ru)
        let seq = try #require(kb.tapOption().selectionSeq)
        let retype = try #require(kb.send(.selectionRead(seq: seq, text: "руддщ цщкдв")).retype)
        #expect(retype.text == "hello world")
        #expect(retype.target == en)
    }

    @Test func nothingSelectedReleases() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        kb.press(0)
        #expect(kb.send(.selectionRead(seq: seq, text: "")).effects == [.refused(.nothingSelected), .releaseHeld])
        #expect(!kb.machine.isHolding)
        #expect(kb.machine.currentLayout == en, "no layout change")
    }

    @Test(arguments: ["first line\nsecond", "tab\there", "1234 5678", "🙂🙂",
                      String(repeating: "f", count: SelectionConversion.maxLength + 1)])
    func unsupportedSelectionIsRefused(text: String) throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.selectionRead(seq: seq, text: text)).effects == [.refused(.unsupportedSelection), .releaseHeld])
    }

    @Test func staleAnswerIsIgnored() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.selectionRead(seq: seq + 1, text: "ghbdtn")).effects.isEmpty)
        #expect(kb.machine.isHolding)
        #expect(kb.send(.retypePosted(seq: seq, time: kb.time)).effects.isEmpty, "nothing posted yet")
    }

    @Test func timeoutWhileReadingReleasesAndLateAnswerIsIgnored() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        kb.press(0)
        kb.time += Settings().postTimeout
        #expect(kb.send(.deadline(time: kb.time)).effects == [.releaseHeld])
        #expect(kb.send(.selectionRead(seq: seq, text: "ghbdtn")).effects.isEmpty)
        #expect(kb.machine.currentLayout == en)
    }

    @Test func cancelWhileReadingReleases() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.retypeCancelled(seq: seq)).effects == [.releaseHeld])
    }

    @Test func cancelledSelectionRetypeRestoresLayout() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        kb.send(.selectionRead(seq: seq, text: "ghbdtn"))
        #expect(kb.send(.retypeCancelled(seq: seq)).effects == [.selectLayout(en), .releaseHeld])
        #expect(kb.machine.currentLayout == en)
    }

    @Test func ownCopyKeysPassWithoutReleasing() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        // ⌘C posted to read the selection.
        #expect(kb.modifiers(keyCode: 55, flags: Keyboard.leftCommand, origin: .own(seq: seq, last: false))
            .disposition == .pass)
        #expect(kb.press(8, flags: Keyboard.leftCommand, origin: .own(seq: seq, last: false)) == Output())
        #expect(kb.machine.isHolding)
    }

    @Test func accessibilityReplacementReleasesOnPosted() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        let retype = try #require(kb.send(.selectionRead(seq: seq, text: "ghbdtn", viaAccessibility: true)).retype)
        #expect(retype.viaAccessibility)
        kb.time += 0.01
        #expect(kb.send(.retypePosted(seq: seq, time: kb.time)).effects
            == [.scheduleDeadline(at: kb.time + Settings().fenceTimeout)])
        #expect(kb.send(.layoutChanged(ru)).effects == [.releaseHeld])
    }

    @Test func nextShortcutAfterSelectionRetypesWordAgain() throws {
        var kb = Keyboard()
        let seq = try #require(kb.tapOption().selectionSeq)
        let retype = try #require(kb.send(.selectionRead(seq: seq, text: "ghbdtn")).retype)
        kb.completeRetype(retype)
        // The selection is replaced; nothing typed since, so it reads the selection again.
        let next = kb.tapOption()
        #expect(next.startsSelectionConversion)
        #expect(next.selectionSeq != seq)
    }
}

@Suite struct SelectionConversionTests {
    private let layouts = [Fixture.abc, Fixture.russian, Fixture.ukrainianPC]

    @Test(arguments: [
        ("ghbdtn", Fixture.abc.id),
        ("Hello, world!", Fixture.abc.id),
        ("привет", Fixture.russian.id),
        ("ёлка", Fixture.russian.id),
        ("Їжак і ґанок", Fixture.ukrainianPC.id),
        ("мы", Fixture.russian.id),
    ])
    func detectsSourceLayout(text: String, expected: LayoutID) {
        #expect(SelectionConversion.sourceLayout(of: text, among: layouts)?.id == expected)
    }

    @Test func tieGoesToFirst() {
        // Ukrainian-PC and Russian both type these letters.
        #expect(SelectionConversion.sourceLayout(of: "привет", among: [Fixture.ukrainianPC, Fixture.russian])?.id
            == Fixture.ukrainianPC.id)
        #expect(SelectionConversion.sourceLayout(of: "1 2", among: layouts)?.id == Fixture.abc.id)
        #expect(SelectionConversion.sourceLayout(of: "🙂", among: layouts) == nil)
    }

    @Test func keysUseSourceStrokes() {
        let keys = SelectionConversion.keys(for: "Ghbdtn 42🙂", from: Fixture.abc, to: Fixture.russian)
        #expect(keys.map(\.text).joined() == "Привет 42🙂")
        #expect(keys.prefix(6).map(\.stroke) == Fixture.abc.strokes("Ghbdtn"))
        #expect(keys.last?.stroke == KeyStroke(KeyCode.space), "no layout types the emoji")
    }

    @Test func russianPunctuationKeys() {
        let keys = SelectionConversion.keys(for: "юб", from: Fixture.russian, to: Fixture.abc)
        #expect(keys.map(\.text).joined() == ".,")
    }
}
