// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

/// The words of the voice dictionary in the personal lexicon store
/// (docs/classifier.md, «Общие слова»).
@MainActor
struct SharedWordsStoreTests {
    typealias Desk = PersonalLexiconStoreTests.Desk

    private func fingerprint(_ word: String, key: PersonalKey?, language: LanguageCode = "en") throws -> UInt64 {
        try #require(key).fingerprint(ofWord: word, language: language)
    }

    private func key(_ desk: Desk) throws -> PersonalKey {
        try #require(try desk.keys.load())
    }

    /// Five confirmations on five days: the word is accepted.
    private func teach(_ store: PersonalLexiconStore, _ desk: Desk, _ word: String, key: PersonalKey) {
        let scalars = word.unicodeScalars.map(\.value)
        let observation = PersonalObservation(
            word: key.fingerprint(.word, language: "en", scalars),
            start3: key.fingerprint(.start3, language: "en", scalars.prefix(3)),
            start4: key.fingerprint(.start4, language: "en", scalars.prefix(4)), language: "en")
        for _ in 0..<5 {
            store.record(PersonalTally(observations: [observation], generation: 0))
            desk.day += 1
            desk.seconds += 31
        }
    }

    @Test func offTheSharedWordsChangeNothing() {
        let desk = Desk()
        let store = desk.store()
        store.setSharedWords(["Perekey"])
        store.setEnabled(false)
        #expect(store.lexicon == .off && desk.changes.isEmpty && desk.keys.created == 0 && !desk.file.exists)
        store.setSharedWords(["Perekey", "Дашка"])
        #expect(store.lexicon == .off && desk.changes.isEmpty && desk.keys.created == 0)
        store.flush()
        #expect(!desk.file.exists)
    }

    @Test func aProfileThatForbidsTheLexiconKeepsTheSharedWordsOut() {
        let desk = Desk()
        let store = desk.store(allowed: false)
        store.setSharedWords(["Perekey"])
        store.setEnabled(true, allowed: false)
        #expect(store.lexicon == .off && desk.changes.isEmpty && desk.keys.created == 0)
    }

    @Test func onTheWordIsAcceptedAtOnceWithNoObservation() throws {
        let desk = Desk()
        let store = desk.store()
        store.setSharedWords(["перекей", "Perekey"])
        store.setEnabled(true)
        let lexicon = try #require(desk.changes.last)
        let key = try key(desk)
        #expect(lexicon.containsWord(try fingerprint("perekey", key: key)))
        #expect(lexicon.containsStart(key.fingerprint(.start3, language: "en", "per".unicodeScalars.map(\.value))))
        #expect(lexicon.hasWords && lexicon.mayHold("en"))
        #expect(store.heldEntryCount == 0, "no entry, no count")
        #expect(store.wordCount == 0, "the pane counts the words it learned")
        #expect(!desk.file.exists)
    }

    @Test func aWordSharedWhileItIsOnReachesTheTapOnce() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let before = desk.changes.count
        store.setSharedWords(["Perekey"])
        #expect(desk.changes.count == before + 1)
        let key = try key(desk)
        #expect(desk.changes.last?.containsWord(try fingerprint("perekey", key: key)) == true)
        // The same list, another spelling of the same word, an unrelated change: nothing new for the tap.
        store.setSharedWords(["Perekey"])
        store.setSharedWords(["PEREKEY"])
        store.setSharedWords(["PEREKEY", "Perekey"])
        #expect(desk.changes.count == before + 1)
    }

    @Test func aRecordThatGoesTakesItsWordWithIt() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        store.setSharedWords(["Perekey", "Дашка"])
        let key = try key(desk)
        let before = desk.changes.count
        store.setSharedWords(["Дашка"])
        #expect(desk.changes.count == before + 1)
        let lexicon = try #require(desk.changes.last)
        #expect(!lexicon.containsWord(try fingerprint("perekey", key: key)))
        #expect(lexicon.containsWord(try fingerprint("дашка", key: key, language: "ru")))
        store.setSharedWords([])
        #expect(desk.changes.count == before + 2)
        #expect(desk.changes.last?.hasWords == false && desk.changes.last?.isOn == true)
    }

    @Test func aWordTheSetTaughtStaysWhenItsRecordGoes() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try key(desk)
        teach(store, desk, "perekey", key: key)
        #expect(store.wordCount == 1)
        let taught = try #require(desk.changes.last)
        store.setSharedWords(["Perekey"])
        #expect(desk.changes.last == taught, "taught and shared: in the snapshot once, the tap is told nothing new")
        store.setSharedWords([])
        #expect(store.lexicon.containsWord(try fingerprint("perekey", key: key)))
        #expect(store.lexicon.containsStart(key.fingerprint(.start4, language: "en", "pere".unicodeScalars.map(\.value))))
        #expect(store.wordCount == 1)
    }

    @Test func aSharedWordIsNotCountedAndTheFileHoldsNothingOfIt() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try key(desk)
        store.setSharedWords(["Perekey"])
        teach(store, desk, "perekey", key: key)
        #expect(store.heldEntryCount == 0, "the dictionary has the word: the batch does not make an entry")
        teach(store, desk, "dashkaa", key: key)
        store.flush()
        let data = try Data(contentsOf: desk.file.url)
        let json = String(decoding: data, as: UTF8.self)
        let shared = "perekey"
        #expect(!json.localizedCaseInsensitiveContains(shared))
        let fingerprints = [try fingerprint(shared, key: key),
                            key.fingerprint(.start3, language: "en", "per".unicodeScalars.map(\.value)),
                            key.fingerprint(.start4, language: "en", "pere".unicodeScalars.map(\.value)),
                            ModelFormat.Fingerprint.of(shared.unicodeScalars, folded: true),
                            ModelFormat.Fingerprint.of(shared.unicodeScalars, folded: false)]
        for hash in fingerprints {
            #expect(!json.contains(PersonalLexiconFile.hex(hash)), "the file has no fingerprint of a shared word")
            #expect(!json.contains(String(hash)))
        }
        #expect(json.contains(PersonalLexiconFile.hex(try fingerprint("dashkaa", key: key))), "the learned word is there")
        #expect(!json.unicodeScalars.contains { $0.value > 0x7F })
    }

    @Test func aSharedWordTheModelCountsAlreadyKeepsCounting() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try key(desk)
        // A candidate: seen twice, not accepted.
        for _ in 0..<2 {
            teachOnce(store, key: key, word: "perekey")
        }
        #expect(store.heldEntryCount == 1)
        store.setSharedWords(["Perekey"])
        teachOnce(store, key: key, word: "perekey")
        #expect(store.heldEntryCount == 1)
        desk.day += 1
        for _ in 0..<2 { teachOnce(store, key: key, word: "perekey") }
        desk.day += 1
        teachOnce(store, key: key, word: "perekey")
        #expect(store.wordCount == 1, "the count went on: the word is taught as well")
    }

    private func teachOnce(_ store: PersonalLexiconStore, key: PersonalKey, word: String) {
        let scalars = word.unicodeScalars.map(\.value)
        let observation = PersonalObservation(word: key.fingerprint(.word, language: "en", scalars),
                                              start3: nil, start4: nil, language: "en")
        store.record(PersonalTally(observations: [observation], generation: 0))
    }

    @Test func eraseKeepsTheSharedWordsUnderTheNewKey() throws {
        let desk = Desk()
        let store = desk.store()
        store.setSharedWords(["Perekey"])
        store.setEnabled(true)
        let first = try key(desk)
        store.erase()
        let second = try key(desk)
        #expect(first != second)
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.key == second)
        #expect(lexicon.containsWord(try fingerprint("perekey", key: second)))
        #expect(!lexicon.containsWord(try fingerprint("perekey", key: first)))
    }

    @Test func turningItOffForgetsTheFingerprintsAndOnReadsThemAgain() throws {
        let desk = Desk()
        let store = desk.store()
        store.setSharedWords(["Perekey"])
        store.setEnabled(true)
        store.setEnabled(false)
        #expect(store.lexicon == .off && desk.changes.last == .off)
        store.setSharedWords(["Perekey", "Дашка"])
        #expect(desk.changes.last == .off)
        store.setEnabled(true)
        let key = try key(desk)
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.containsWord(try fingerprint("perekey", key: key)))
        #expect(lexicon.containsWord(try fingerprint("дашка", key: key, language: "ru")))
    }

    @Test func theRecordingsStoreHasNoSharedWords() throws {
        let desk = Desk()
        let store = desk.store(sessionOnly: true)
        store.setSharedWords(["Perekey"])
        store.setEnabled(true)
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.isOn && !lexicon.hasWords)
    }
}
