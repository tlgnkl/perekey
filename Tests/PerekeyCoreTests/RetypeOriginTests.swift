// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

private func settings(_ action: HotkeyAction) -> Settings {
    Settings(hotkeys: [HotkeyBinding(.modifiers(.option, taps: .single), action: action)])
}

/// A keyboard with a classifier and a focused text field.
private func keyboard(_ action: HotkeyAction, autoswitch: Bool = true) -> Keyboard {
    var settings = settings(action)
    settings.autoswitch = autoswitch
    var kb = Keyboard(settings)
    kb.machine = InputMachine(settings: settings, layouts: [Fixture.abc, Fixture.russian], currentLayout: en,
                              classifier: Desk.classifier)
    kb.send(.focusChanged(Desk.textEdit))
    return kb
}

@Suite struct RetypeOriginTests {
    @Test func anAutomaticSwitchSaysSoAndCarriesItsDecision() throws {
        var desk = Desk()
        // No impossible start: it is judged at the space, not inside the word.
        desk.type("[jhjij ")
        let retype = try #require(desk.history.first)
        #expect(retype.origin == .automatic(.layout))
        let decision = try #require(retype.decision)
        #expect(decision.verdict == .switch(to: ru))
        #expect(decision.margin == 10)
        let correction = try #require(desk.corrections.first)
        #expect(correction.decision == decision)
        #expect(!correction.insideWord)
    }

    @Test func aSwitchInsideTheWordHasNoDecisionButSaysWhere() throws {
        var desk = Desk()
        desk.type("ghb")
        let retype = try #require(desk.history.first)
        #expect(retype.origin == .automatic(.layout))
        #expect(retype.decision == nil)
        desk.type("dtn ")
        let correction = try #require(desk.corrections.first)
        #expect(correction.insideWord)
        #expect(correction.decision?.typedLanguage == "en")
    }

    @Test func theUndoOfACorrectionIsNoManualRetype() throws {
        var desk = Desk()
        desk.type("ghbdtn ")
        desk.press(KeyCode.delete)
        #expect(desk.history.last?.origin == .undo)
    }

    @Test func theRetypeShortcutIsManualAndExplainsTheLeftAloneWord() throws {
        var kb = keyboard(.convertLastWord)
        kb.type("hello", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.origin == .manual(.convertLastWord))
        // Automatic switching would have kept this word.
        let decision = try #require(retype.decision)
        #expect(decision.verdict == .keep)
    }

    @Test func aJudgedWordKeepsTheDecisionMadeAtItsEnd() throws {
        var kb = keyboard(.convertLastWord)
        kb.type("hello ", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        let decision = try #require(retype.decision)
        #expect(decision.verdict == .keep)
        #expect(decision.reason == .compared)
    }

    @Test func noDecisionWhenAutomaticSwitchingWasOff() throws {
        var kb = keyboard(.convertLastWord, autoswitch: false)
        kb.type("hello", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.origin == .manual(.convertLastWord))
        #expect(retype.decision == nil)
    }

    @Test func noDecisionWhereTheAppModeForbidsIt() throws {
        var kb = keyboard(.convertLastWord)
        kb.send(.appModeChanged(.manualOnly))
        kb.type("hello", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).decision == nil)
    }

    @Test func changeCaseNamesItsAction() throws {
        var kb = keyboard(.changeCase)
        kb.type("hello", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.origin == .manual(.changeCase))
        #expect(retype.decision == nil)
    }

    @Test func aSelectionNamesTheActionThatReadIt() throws {
        for (action, expected) in [(HotkeyAction.transliterate, HotkeyAction.transliterate),
                                   (.convertLastWord, .convertLastWord), (.changeCase, .changeCase)]
        {
            var kb = keyboard(action)
            let seq: UInt32 = try {
                guard case let .convertSelection(seq)? = kb.tapOption().effects.first(where: {
                    if case .convertSelection = $0 { true } else { false }
                }) else { throw Failure.none }
                return seq
            }()
            let text = action == .transliterate ? "privet" : action == .changeCase ? "hello" : "ghbdtn"
            let retype = try #require(kb.send(.selectionRead(seq: seq, text: text, viaAccessibility: false)).retype)
            #expect(retype.origin == .manual(expected))
        }
    }

    private enum Failure: Error { case none }
}

@Suite struct TypoChangeTests {
    @Test func aTypoCorrectionNamesWhatItChanged() throws {
        var desk = Desk(current: ru)
        desk.type("прривет ", on: Fixture.russian)
        let correction = try #require(desk.corrections.first)
        #expect(correction.kind == .typo)
        #expect(correction.typoChange == .delete)
        #expect(desk.history.first?.origin == .automatic(.typo))
    }
}
