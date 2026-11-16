// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// The slip guard (`Classifier.Options.typoWordRank`) through the machine, not only `classify`:
/// the word typed on ABC, a space after it, the text the field holds.
@Suite struct TypoGuardDeskTests {
    /// The fixture plus Russian words that begin like the Russian reading of "hte" and "taht",
    /// so that the guard acts on the third key of "hte" and the fourth of "taht" ("tah" starts "tahini").
    static let model = ModelFixture.model(withEnglishWords: [("tahini", 120)], russianWords: [("реутов", 200), ("ефрем", 200), ("плен", 200)],
                                          russianPairs: [])

    private func desk(rank: UInt8) -> Desk {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        options.typoWordRank = rank
        return Desk(classifier: Classifier(model: Self.model, options: options))
    }

    /// Off, the word switches inside, as on main.
    @Test(arguments: [("hte ", "реу "), ("taht ", "ефре ")])
    func offTheSwapSwitchesAsOnMain(typed: String, expected: String) {
        var desk = desk(rank: 0)
        desk.type(typed)
        #expect(desk.text == expected)
    }

    @Test func onTheSwapStaysInEnglish() {
        var desk = desk(rank: 160)
        desk.type("hte ")
        #expect(desk.text == "hte ")
        #expect(desk.appLayout == Fixture.abc.id)
        #expect(desk.corrections.isEmpty)
    }

    /// "taht": nothing switches on the third or the fourth key. The end of the word is the classifier's:
    /// on the real model it keeps ("bothPlausible"; the fixture has too few words to say the same).
    @Test func aSwapOfFourLettersIsNotSwitchedInsideTheWord() {
        var desk = desk(rank: 160)
        desk.type("taht")
        #expect(desk.text == "taht")
        #expect(desk.corrections.isEmpty)
    }

    @Test(arguments: [("ghbdtn ", "привет "), ("ytn ", "нет "), ("gkt ", "пле "), ("vbh ", "мир ")])
    func wordsThatAreNoSlipSwitchInBothModes(typed: String, expected: String) {
        for rank: UInt8 in [0, 160] {
            var desk = desk(rank: rank)
            desk.type(typed)
            #expect(desk.text == expected, "rank \(rank)")
            #expect(desk.appLayout == Fixture.russian.id, "rank \(rank)")
        }
    }

    /// The window of the fifth key opens for the word the guard held, and for that word only.
    @Test func theFifthKeyIsLookedAtOnlyAfterTheGuardHeld() {
        var held = desk(rank: 160)
        held.type("taht")
        #expect(held.text == "taht")
        #expect(held.machine.judge.gate.slipHeld)
        held.type("s")
        #expect(held.text == "ефреы")

        var plain = desk(rank: 160)
        plain.type("ghbdt")
        #expect(!plain.machine.judge.gate.slipHeld)
    }
}
