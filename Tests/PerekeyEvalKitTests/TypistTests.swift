// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk
@testable import PerekeyEvalKit
import Testing

@Suite struct TypistTests {
    let typist = Typist()

    func events(_ item: EvalCase) throws -> [TypedEvent] {
        try typist.events(for: item, layouts: Repo.library)
    }

    @Test func shiftGoesAroundACapitalAsAModifier() throws {
        let typed = try events(Cases.make([.type("Hi", on: "ABC")], want: "Hi"))
        let shift = Typist.flag(.leftShift)
        #expect(typed.map(\.event).prefix(6) == [
            .flags(keyCode: 56, flags: shift),
            .keyDown(keyCode: 4, flags: shift),
            .keyUp(keyCode: 4, flags: shift),
            .flags(keyCode: 56, flags: 0),
            .keyDown(keyCode: 34, flags: 0),
            .keyUp(keyCode: 34, flags: 0),
        ])
    }

    @Test func capitalsInARowShareOneHold() throws {
        let typed = try events(Cases.make([.type("OK", on: "ABC")], want: "OK"))
        let flags = typed.map(\.event).filter { if case .flags = $0 { true } else { false } }
        #expect(flags.count == 2)
    }

    @Test func timesGoUpAndFollowThePace() throws {
        let calm = try events(Cases.make([.type("ab", on: "ABC")], want: "ab"))
        #expect(calm.map(\.time) == [100, 100.02, 100.07, 100.09, 100.14])
        let burst = try events(Cases.make([.type("ab", on: "ABC")], want: "ab", env: Env(pace: .burst)))
        #expect(burst.map(\.time) == [100, 100.01, 100.04, 100.05, 100.08])
        let switched = try events(Cases.make([.type("a", on: "ABC"), .pace(.burst), .type("b", on: "ABC")], want: "ab"))
        #expect(switched.map(\.time) == [100, 100.02, 100.05, 100.06, 100.09])
    }

    @Test func aShortcutComesFromTheSettingsAfterAPause() throws {
        let typed = try events(Cases.make([.type("a", on: "ABC"), .hotkey(.switchLayout)], want: "a"))
        let shift = Typist.flag(.leftShift)
        #expect(typed[2].event == .flags(keyCode: 56, flags: shift))
        #expect(abs(typed[2].time - typed[1].time - 0.3) < 1e-9)
        #expect(typed[3].event == .flags(keyCode: 56, flags: 0))
        #expect(abs(typed[3].time - typed[2].time - 0.08) < 1e-9)
    }

    @Test func aChordOfBothShiftsPressesBoth() {
        #expect(Typist.keys(for: .bothShifts) == [.leftShift, .rightShift])
        #expect(Typist.keys(for: .optionShift) == [.leftShift, .leftOption])
        #expect(Typist.keys(for: .rightCommand) == [.rightCommand])
    }

    @Test func theCaseEndsWithAPause() throws {
        let typed = try events(Cases.make([.type("a", on: "ABC")], want: "a"))
        #expect(typed.last?.event == .idle(seconds: 2))
        #expect(typed.last?.step == nil)
    }

    @Test func eventsKnowTheirStepAndCharacter() throws {
        let typed = try events(Cases.make([.type("aB", on: "ABC"), .key(.backspace, n: 1, mods: nil)], want: "a"))
        #expect(typed.map(\.step) == [0, 0, 0, 0, 0, 0, 1, 1, nil])
        #expect(typed.map(\.char) == [0, 0, 1, 1, 1, 1, nil, nil, nil])
    }

    /// Shift held for capitals must never read as the Shift shortcut.
    @Test func aThousandWordsWithCapitalsSwitchNoLayout() throws {
        let words = (0..<1000).map { ["Hello", "World", "The", "KEYBOARD", "iPhone", "OK", "Code"][$0 % 7] }
        let text = words.joined(separator: " ") + " "
        for pace in Pace.allCases {
            let item = Cases.make([.type(text, on: "ABC")], want: String(text.dropLast()),
                                  env: Env(settings: "off", pace: pace), scoring: .case)
            let played = try Cases.play(item)
            #expect(played.out.layout == Repo.abc.id, "\(pace)")
            #expect(played.out.text == text, "\(pace)")
            #expect(played.null.text == text, "\(pace)")
        }
    }
}
