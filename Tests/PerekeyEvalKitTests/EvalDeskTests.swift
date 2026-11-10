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

    @Test func aRetypeIsCancelledWhenTheTextBeforeTheCaretDiffers() throws {
        // The desk is behind; the person clicks to the start before it catches up.
        let played = try play([.type("хорошо ", on: "Russian"), .click(.start)], env: Env(pace: .burst, lag: 99))
        // The held space goes where the caret is now.
        #expect(played.out.text == " [jhjij")
        #expect(played.out.corrections == 0)
        #expect(played.out.trace.contains { $0.kind == .cancelled })
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
        #expect(played.null.layout == Repo.russian.id, "without Perekey the system's shortcut switches")
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
