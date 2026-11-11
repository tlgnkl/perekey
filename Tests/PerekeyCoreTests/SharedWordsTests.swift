// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// The words the voice dictionary names as the user's own, as the personal
/// lexicon takes them (docs/classifier.md, «Общие слова»).
@Suite struct SharedWordsTests {
    let classifier = Desk.classifier
    let model = PersonalLexiconModel()

    private func shared(_ texts: String...) -> [PersonalObservation] {
        personalKey.sharedObservations(of: texts)
    }

    private func snapshot(_ texts: String..., model: PersonalLexiconModel = PersonalLexiconModel()) -> PersonalLexicon {
        model.snapshot(key: personalKey, shared: personalKey.sharedObservations(of: texts))
    }

    @Test func theFingerprintIsTheOneOfAWordTheUserTyped() {
        // The same key, domain, language and spelling as `Classifier.personalObservation`: case and «ё» do not matter.
        for text in ["Perekey", "perekey", "PEREKEY"] {
            #expect(shared(text) == [personalObservation("perekey", "en")], Comment(rawValue: text))
        }
        let artem = shared("Артём")
        #expect(Set(artem.map(\.language)) == ["ru", "uk", "be", "kk"])
        #expect(artem == shared("артем"))
        #expect(artem.contains(personalObservation("артем", "ru")))
        #expect(artem.contains(personalObservation("артём", "ru")))
    }

    @Test func aWordOfOneScriptGetsTheLanguagesOfThatScript() {
        #expect(Set(shared("Perekey").map(\.language)) == ["en"])
        #expect(Set(shared("Дашка").map(\.language)) == ["ru", "uk", "be", "kk"])
        #expect(shared("Дашка").count == 4)
    }

    @Test func aTextIsSplitIntoWordsAndTheMarksAroundThemAreCut() {
        #expect(shared("Open Source") == shared("open") + shared("source"))
        #expect(shared("«Perekey».") == shared("Perekey"))
        #expect(shared("iPhone") == shared("iphone"), "a capital inside is no reason to leave the word out")
    }

    @Test func whatTheClassifierNeverReadsAsAWordIsLeftOut() {
        let minimum = PersonalOptions().minLetters
        let short = String(repeating: "a", count: minimum - 1)
        let long = String(repeating: "a", count: PersonalOptions().maxLetters + 1)
        for text in [short, long, "Perekey2", "2Perekey", "Perekey.2", "Pere-key", "it's", "123456", "Perеkey", "日本語日本語", "", "   ", "..."] {
            #expect(shared(text).isEmpty, "«\(text)»")
        }
        #expect(!shared(String(repeating: "a", count: minimum)).isEmpty)
    }

    @Test func theStartsAreThoseOfTheEarlySwitch() {
        let word = shared("Perekey")[0]
        #expect(word.start3 == personalKey.fingerprint(.start3, language: "en", "per".unicodeScalars.map(\.value)))
        #expect(word.start4 == personalKey.fingerprint(.start4, language: "en", "pere".unicodeScalars.map(\.value)))
        let four = shared("Perk")[0]
        #expect(four.start4 != nil)
    }

    @Test func aSharedWordIsAcceptedAtOnceWithNoObservation() {
        let lexicon = snapshot("Perekey")
        #expect(model.entries.isEmpty && lexicon.hasWords && lexicon.wordCount == 1)
        let strokes = Fixture.abc.strokes("perekey")
        #expect(classifier.isPersonal(strokes, in: Fixture.abc, personal: lexicon))
        #expect(classifier.startsPersonalWord(strokes.prefix(3), in: Fixture.abc, personal: lexicon))
        #expect(classifier.startsPersonalWord(strokes.prefix(4), in: Fixture.abc, personal: lexicon))
        #expect(!classifier.isPersonal(strokes, in: Fixture.abc, personal: snapshot()))
    }

    @Test func theSharedWordIsKeptAndSwitchedTo() {
        let strokes = Fixture.abc.strokes("perekey")
        func decide(_ personal: PersonalLexicon, typed: LayoutMap, other: LayoutMap, text: [KeyStroke]) -> Classifier.Decision {
            classifier.classify(text, typed: typed, other: other,
                                context: Classifier.Context(recent: RecentLanguages(), personal: personal))
        }
        let lexicon = snapshot("Perekey")
        // Typed right: it stays. Typed in the wrong layout: it switches to the word.
        #expect(decide(lexicon, typed: Fixture.abc, other: Fixture.russian, text: strokes).verdict == .keep)
        #expect(decide(lexicon, typed: Fixture.russian, other: Fixture.abc, text: strokes).verdict == .switch(to: Fixture.abc.id))
        #expect(decide(.off, typed: Fixture.russian, other: Fixture.abc, text: strokes).verdict != .switch(to: Fixture.abc.id))
    }

    @Test func aLearnedWordSurvivesTheEndOfItsSharedRecord() {
        var learned = PersonalLexiconModel()
        let observation = personalObservation("perekey", "en")
        for day in 1...5 { learned.record(PersonalTally(observations: [observation], generation: 0), day: day) }
        #expect(learned.acceptedCount == 1)
        let both = learned.snapshot(key: personalKey, shared: shared("Perekey"))
        let alone = learned.snapshot(key: personalKey)
        #expect(both == alone, "a word taught and shared is in the snapshot once, with the starts of the learned entry")
        #expect(both.containsWord(observation.word))
        // And the lexicon with the record gone is the one of the model alone: the shared word is no entry.
        #expect(model.snapshot(key: personalKey, shared: shared("Perekey")) != model.snapshot(key: personalKey))
    }
}
