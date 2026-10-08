// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct LayoutMapTests {
    @Test(arguments: [
        ("ghbdtn", "привет"),
        (",eltn", "будет"),
        ("Ghbdtn", "Привет"),
        ("[jhjij", "хорошо"),
        ("'nj", "это"),
        ("j;bl", "ожид"),
        ("ds,jh", "выбор"),
        ("\\krf", "ёлка"),
    ])
    func englishToRussian(typed: String, meant: String) {
        #expect(Fixture.russian.convert(typed, from: Fixture.abc) == meant)
        #expect(Fixture.abc.convert(meant, from: Fixture.russian) == typed)
    }

    @Test func capsLockAndShift() {
        let strokes = Fixture.abc.strokes("ghbdtn").map { KeyStroke($0.keyCode, .capsLock) }
        #expect(Fixture.abc.type(strokes) == "GHBDTN")
        #expect(Fixture.russian.type(strokes) == "ПРИВЕТ")
        let shifted = strokes.map { KeyStroke($0.keyCode, [.capsLock, .shift]) }
        #expect(Fixture.russian.type(shifted) == "ПРИВЕТ")
    }

    @Test func unknownCharactersStay() {
        #expect(Fixture.russian.convert("ghbdtn 42 🙂", from: Fixture.abc) == "привет 42 🙂")
    }

    @Test func russianPCDiffersFromRussian() {
        // Russian – PC has "ё" on the ` key and "." on the / key, as on Windows.
        #expect(Fixture.russianPC.convert("`krf", from: Fixture.abc) == "ёлка")
        #expect(Fixture.russianPC.text(for: KeyStroke(44)) == ".")
        #expect(Fixture.russian.text(for: KeyStroke(44)) == "/")
    }

    @Test func ukrainianLetters() {
        #expect(Fixture.ukrainianPC.convert("ghbdsn", from: Fixture.abc) == "привіт")
    }

    @Test func deadKeys() {
        let acute = KeyStroke(14, .option) // ⌥E
        #expect(Fixture.abc.isDeadKey(acute))
        #expect(Fixture.abc.text(for: acute) == nil)
        #expect(!Fixture.russian.isDeadKey(acute))
    }

    @Test func reversePrefersFewestModifiers() {
        #expect(Fixture.abc.stroke(for: "a") == KeyStroke(0))
        #expect(Fixture.abc.stroke(for: "A") == KeyStroke(0, .shift))
    }

    @Test(arguments: ["ABC", "US", "USExtended", "Russian", "RussianWin", "Ukrainian-PC"])
    func codableRoundTrip(name: String) throws {
        let map = Fixture.layout(name)
        let decoded = try JSONDecoder().decode(LayoutMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(map.language != nil)
    }
}

@Suite struct SyntheticMarkTests {
    @Test func roundTrip() {
        for mark in [SyntheticMark.own(seq: 1, last: false), .own(seq: .max, last: true), .replayed] {
            #expect(SyntheticMark(userData: mark.userData) == mark)
        }
    }

    @Test func foreignDataIsNotOurs() {
        #expect(SyntheticMark(userData: 0) == nil)
        #expect(SyntheticMark(userData: 42) == nil)
        #expect(SyntheticMark(userData: -1) == nil)
    }
}
