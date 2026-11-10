// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk
@testable import PerekeyEvalKit
import Testing

/// The scenes of the `Desk` tests (Tests/PerekeyCoreTests/AutoswitchTests.swift)
/// played on `EvalDesk` with the same fixture model: the same text.
@Suite struct EvalDeskTests {
    func play(_ script: [Step], env: Env? = nil, start: String = "ABC") throws -> Runner.Played {
        try Cases.play(Cases.make(script, want: "-", start: start, env: env, scoring: .case))
    }

    @Test func aWordInTheWrongLayoutIsSwitchedAtTheSpace() throws {
        let played = try play([.type("привет ", on: "Russian")])
        #expect(played.out.text == "привет ")
        #expect(played.out.layout == Repo.russian.id)
        #expect(played.out.corrections == 1)
        #expect(played.null.text == "ghbdtn ")
    }

    @Test func fastTypingWithTheDeskBehindGivesPrivetMir() throws {
        // `Desk.type("ghbdtn vbh", settling: false)`, then `settle()`.
        let played = try play([.type("привет мир", on: "Russian")], env: Env(pace: .burst, lag: 99))
        #expect(played.out.text == "привет мир")
    }

    @Test(arguments: [0, 1, 3])
    func fastTypingKeepsOrderAndLayoutAtAnyLag(lag: Int) throws {
        let played = try play([.type("привет мир ", on: "Russian")], env: Env(pace: .burst, lag: lag))
        #expect(played.out.text == "привет мир ")
    }

    @Test func impossibleStartSwitchesInsideTheWord() throws {
        let played = try play([.type("привет ", on: "Russian")])
        let entry = try #require(played.out.trace.first)
        #expect(entry.kind == .switched)
        #expect(entry.insideWord == true)
    }

    @Test func backspaceRightAfterUndoes() throws {
        // `backspaceRightAfterUndoesAndLearns`: "[jhjij " and Backspace give "[jhjij ".
        let played = try play([.type("хорошо ", on: "Russian"), .key(.backspace, n: nil, mods: nil)])
        #expect(played.out.text == "[jhjij ")
        #expect(played.out.undone == 1)
        #expect(played.out.layout == Repo.abc.id)
    }

    @Test func theUndoButtonUndoesTheLastCorrection() throws {
        let played = try play([.type("хорошо ", on: "Russian"), .click(.hint), .undo(.button)])
        #expect(played.out.text == "[jhjij ")
        #expect(played.out.undone == 1)
    }

    /// The caret check runs when the retype is asked for (`InputEngine.beginCheck`),
    /// not when the main thread gets to it: a click after that does not cancel it,
    /// and the retype lands at the caret, as in the app.
    @Test func theCaretCheckIsTakenWhenTheRetypeIsAskedFor() throws {
        let played = try play([.type("хорошо ", on: "Russian"), .click(.start)], env: Env(pace: .burst, lag: 99))
        #expect(!played.out.trace.contains { $0.kind == .cancelled })
        #expect(played.out.corrections == 1)
        #expect(played.out.text == "хорошо [jhjij")
    }

    /// A retype that stays in its layout (no `selectLayout`) is posted at
    /// once, as `InputEngine.execute` does; only a selection waits for the main thread.
    @Test func aRetypeWithoutALayoutChangeIsPostedAtOnce() throws {
        let item = Cases.make([.type("ПРивет мир", on: "Russian")], want: "-", start: "Russian",
                              env: Env(pace: .burst, lag: 99), scoring: .case)
        var desk = try recordingDesk(item)
        let events = try Typist().events(for: item, layouts: Repo.library)
        let space = try #require(events.firstIndex { $0.event == .keyDown(keyCode: KeyCode.space, flags: 0) })
        for typed in events[...space] { desk.send(typed.event, at: typed.time) }
        #expect(desk.text.hasPrefix("Привет"))
        #expect(!desk.isBehind)
    }

    /// A retype the fence no longer waits for is not posted, and the machine
    /// hears `inputLost`, as in `InputEngine.postIfPending`.
    @Test func aLateRetypeIsLostInput() throws {
        let item = Cases.make([.type("привет", on: "Russian"), .type(String(repeating: "f", count: 70), on: "ABC")],
                              want: "-", env: Env(pace: .burst, lag: 999), scoring: .case)
        var desk = try recordingDesk(item)
        for typed in try Typist().events(for: item, layouts: Repo.library) { desk.send(typed.event, at: typed.time) }
        desk.finish()
        #expect(desk.records.contains { if case .inputLost = $0.input { true } else { false } })
        #expect(!desk.records.contains { if case .retypePosted = $0.input { true } else { false } })
    }

    func recordingDesk(_ item: EvalCase) throws -> EvalDesk {
        let setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        var machine = try MachineSystem(setup: setup)
        machine.recording = true
        return machine.desk
    }

    @Test func aBlindFieldRetypesWithoutTheCheck() throws {
        let played = try play([.type("хорошо ", on: "Russian")], env: Env(field: .blind))
        #expect(played.out.text == "хорошо ")
    }

    @Test func theCaretInTheMiddleOfTheText() throws {
        let played = try play([.type("world", on: "ABC"), .click(.start), .type("привет ", on: "Russian")])
        #expect(played.out.text == "привет world")
    }

    @Test func theLastRetypeIsNotLostToTheFenceDeadline() throws {
        // The desk catches up before the deadlines of the final pause pass.
        let played = try play([.type("хорошо ", on: "Russian")], env: Env(pace: .burst, lag: 99))
        #expect(played.out.text == "хорошо ")
    }

    @Test func deadlinesAreSent() throws {
        let item = Cases.make([.type("хорошо ", on: "Russian")], want: "-", scoring: .case)
        let setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        var machine = try MachineSystem(setup: setup)
        machine.recording = true
        for typed in try Typist().events(for: item, layouts: Repo.library) {
            try machine.send(typed.event, at: typed.time)
        }
        _ = try machine.finish()
        #expect(machine.desk.records.contains { if case .deadline = $0.input { true } else { false } })
    }

    @Test func modeOffKeepsItQuietAndTakesTheShortcuts() throws {
        let played = try play([.type("привет ", on: "Russian"), .hotkey(.switchLayout)], env: Env(mode: .off))
        #expect(played.out.text == "ghbdtn ")
        #expect(played.out.layout == Repo.abc.id, "the app takes the shortcuts away in off")
        #expect(played.null.layout == Repo.abc.id, "Null takes the shortcuts away in off too: a constant base")
    }

    @Test func nullFollowsTheModeAndSecureInputLikeTheMachine() throws {
        let off = try play([.mode(.off), .hotkey(.switchLayout), .mode(.auto), .hotkey(.switchLayout)])
        #expect(off.null.layout == Repo.russian.id, "off takes the shortcut away, auto gives it back")
        let secure = try play([.secureInput(true), .hotkey(.switchLayout)])
        #expect(secure.null.layout == Repo.abc.id)
        #expect(secure.out.layout == Repo.abc.id)
    }

    @Test(arguments: [AppMode.manualOnly])
    func manualOnlyKeepsItQuietButTheShortcutsWork(mode: AppMode) throws {
        let played = try play([.type("привет", on: "Russian"), .hotkey(.convertLastWord)], env: Env(mode: mode))
        #expect(played.out.text == "привет")
    }

    @Test func passwordFieldsAndSecureInputKeepItQuiet() throws {
        let secure = try play([.focus(.init(app: "com.apple.TextEdit", secure: true)), .type("привет ", on: "Russian")])
        #expect(secure.out.text == "ghbdtn ")
        let input = try play([.type("привет ", on: "Russian")], env: Env(secureInput: true))
        #expect(input.out.text == "ghbdtn ")
    }

    @Test func capsLockTypesCapitalsAndTheDeskKeepsIt() throws {
        let played = try play([.capsLock(true), .type("hello ", on: "ABC")], env: Env(settings: "off"))
        #expect(played.out.text == "HELLO ")
        #expect(played.null.text == "HELLO ")
    }

    @Test func optionBackspaceDeletesTheWord() throws {
        let played = try play([.type("hello world", on: "ABC"), .key(.backspace, n: nil, mods: [.option])],
                              env: Env(settings: "off"))
        #expect(played.out.text == "hello ")
        #expect(played.null.text == "hello ")
    }

    @Test func theDeskStartsInTheCasesLayoutAndFollowsThePerson() throws {
        let played = try play([.type("мир ", on: "Russian"), .layout("ABC"), .type("hello ", on: "ABC")],
                              start: "Russian")
        #expect(played.out.text == "мир hello ")
        #expect(played.null.text == "мир hello ")
    }
}

@Suite struct TextFieldTests {
    @Test func editing() {
        var field = TextField()
        field.insert("hello world")
        field.moveLeft()
        field.extendLeft()
        field.extendLeft()
        #expect(field.selectedText == "rl")
        field.insert("X")
        #expect(field.text == "hello woXd")
        field.place(caret: 5)
        field.deleteWordLeft()
        #expect(field.text == " woXd")
        #expect(field.caret == 0)
        field.backspace()
        #expect(field.text == " woXd")
        field.placeAtEnd()
        #expect(field.textBeforeCaret(endsWith: "Xd"))
        field.deleteLeft(2)
        #expect(field.text == " wo")
    }
}

/// The select step, for the chord detector: Shift down, the arrows, Shift up
/// (`EvalDesk`); Null sees the same events.
@Suite struct SelectStepChordTests {
    func layouts(selecting chars: Int) throws -> (null: LayoutID, machine: LayoutID) {
        let item = Cases.make([.select(chars)], want: "-", scoring: .case)
        var setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        let shift = ModifierChord([.shift: .either])
        setup.settings.hotkeys = [HotkeyBinding(.modifiers(shift, taps: .single), action: .switchLayout)]
        var null = try NullSystem(setup: setup)
        var machine = try MachineSystem(setup: setup)
        for typed in try Typist().events(for: item, layouts: Repo.library) {
            try null.send(typed.event, at: typed.time)
            try machine.send(typed.event, at: typed.time)
        }
        return (try null.finish().layout, try machine.finish().layout)
    }

    @Test func aShiftTapWithoutArrowsSwitchesBoth() throws {
        let played = try layouts(selecting: 0)
        #expect(played.null == played.machine)
        #expect(played.null == Repo.russian.id)
    }

    @Test func arrowsBreakTheTapForBoth() throws {
        let played = try layouts(selecting: 2)
        #expect(played.null == played.machine)
        #expect(played.null == Repo.abc.id)
    }
}
