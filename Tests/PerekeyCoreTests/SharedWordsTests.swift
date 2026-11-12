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

    @Test func aRecordOfOneWordKeepsItsMarksCutAndARecordOfSeveralIsAPhraseNotAWord() {
        // «Ministry of Health» is a phrase: «Ministry» and «Health» are no words of the user's.
        for phrase in ["Ministry of Health", "Open Source", "перекей сервис", " Perekey Mac "] {
            #expect(shared(phrase).isEmpty, "«\(phrase)»")
        }
        #expect(personalKey.sharedObservations(of: ["Ministry of Health", "Perekey"]) == shared("Perekey"))
        #expect(shared("  Perekey \n") == shared("Perekey"))
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

    @Test func theLettersOfNoOtherScriptThanLatinAndCyrillicAreLeftOutWithoutAWord() {
        for text in ["日本語日本語", "Ελληνικά", "עברית", "العربية"] {
            #expect(shared(text).isEmpty, "«\(text)»")
        }
        #expect(shared("日本語日本語", "Perekey") == shared("Perekey"))
    }

    @Test func theWordsOfTheSnapshotAreCappedAtTheLimitOfTheLexiconInTheOrderTheyCome() {
        var options = PersonalOptions()
        options.maxWords = 3
        let words = ["alpha", "bravo", "charlie", "delta", "echoes", "foxtrot"]
        let taken = personalKey.sharedObservations(of: words, options: options)
        #expect(taken == personalKey.sharedObservations(of: Array(words.prefix(3)), options: options))
        #expect(taken.count == 3, "three words, one language each")
        // The same list again: the same words; a word listed twice is one and takes no second place.
        #expect(personalKey.sharedObservations(of: words, options: options) == taken)
        #expect(personalKey.sharedObservations(of: ["alpha", "ALPHA", "bravo", "charlie", "delta"], options: options)
            == personalKey.sharedObservations(of: ["alpha", "bravo", "charlie"], options: options))
        // A phrase and a word that is no word take no place either.
        #expect(personalKey.sharedObservations(of: ["two words", "a1b2c3", "alpha", "bravo", "charlie", "delta"], options: options)
            == taken)
    }

    @Test func moreWordsThanTheLimitAreCutAtTheLimit() {
        let limit = PersonalOptions().maxWords
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        func word(_ n: Int) -> String { "w" + String(String(n, radix: 26).compactMap { Int(String($0), radix: 26) }.map { letters[$0] }) + "xx" }
        let texts = (0..<(limit + 40)).map(word)
        #expect(Set(texts).count == texts.count)
        let taken = personalKey.sharedObservations(of: texts)
        #expect(taken.count == limit)
        #expect(taken.first == shared(texts[0]).first && taken.last == shared(texts[limit - 1]).last, "the first ones, in order")
        #expect(PersonalKey.sharedIdentities(of: texts).count == limit)
        #expect(!PersonalKey.sharedIdentities(of: texts).contains(PersonalKey.sharedIdentity(ofWord: texts[limit])))
    }

    @Test func theIdentityOfAWordIsTheSameForItsSpellings() {
        #expect(PersonalKey.sharedIdentity(ofWord: "Артём") == PersonalKey.sharedIdentity(ofWord: "«артем»"))
        #expect(PersonalKey.sharedIdentity(ofWord: "Perekey") == PersonalKey.sharedIdentity(ofWord: "PEREKEY."))
        #expect(PersonalKey.sharedIdentity(ofWord: "Perekey") != PersonalKey.sharedIdentity(ofWord: "Perekeys"))
        #expect(PersonalKey.sharedIdentities(of: ["Perekey", "Ministry of Health", "Дашка"])
            == [PersonalKey.sharedIdentity(ofWord: "Perekey"), PersonalKey.sharedIdentity(ofWord: "Дашка")])
    }

    @Test func aSuppressedWordIsLeftOutOfTheObservations() {
        let suppressed: Set = [PersonalKey.sharedIdentity(ofWord: "Perekey")]
        #expect(personalKey.sharedObservations(of: ["Perekey", "Дашка"], suppressing: suppressed) == shared("Дашка"))
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
