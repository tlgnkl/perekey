// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

@MainActor
struct PersonalLexiconStoreTests {
    /// A store on a file in a fresh directory, a key in memory, and days and seconds the test sets.
    @MainActor
    final class Desk {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keys: MemoryLexiconKeyStore
        var day = 20_000
        var seconds = 1_000.0
        var changes: [PersonalLexicon] = []
        var file: PersonalLexiconFile { PersonalLexiconFile(url: directory.appending(path: "lexicon.json")) }

        init(keys: MemoryLexiconKeyStore = MemoryLexiconKeyStore()) {
            self.keys = keys
        }

        func store(saveInterval: Double = 30, sessionOnly: Bool = false, allowed: Bool = true,
                   timers: Timers? = nil) -> PersonalLexiconStore
        {
            let store = if let timers {
                PersonalLexiconStore(file: file, keys: keys, saveInterval: saveInterval, today: { self.day },
                                     allowed: allowed, sessionOnly: sessionOnly, clock: { self.seconds },
                                     sleep: { await timers.sleep($0) })
            } else {
                PersonalLexiconStore(file: file, keys: keys, saveInterval: saveInterval, today: { self.day },
                                     allowed: allowed, sessionOnly: sessionOnly, clock: { self.seconds })
            }
            store.onLexiconChanged = { self.changes.append($0) }
            return store
        }

        /// A plain file where the directory should be: a save fails until `unblock`.
        func block() throws {
            try Data().write(to: directory)
        }

        func unblock() throws {
            try FileManager.default.removeItem(at: directory)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The store's timer, run by hand: a test sets the clock and fires the sleeps, and waits for nothing.
    @MainActor
    final class Timers {
        private(set) var delays: [Double] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func sleep(_ seconds: Double) async {
            delays.append(seconds)
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Lets the tasks that were started reach their sleep.
        func settle() async {
            for _ in 0..<10 { await Task.yield() }
        }

        /// Ends every sleep and lets the woken tasks run.
        func fire() async {
            let woken = waiting
            waiting = []
            for continuation in woken { continuation.resume() }
            for _ in 0..<10 { await Task.yield() }
        }
    }

    private func observation(_ number: UInt64, language: LanguageCode = "ru") -> PersonalObservation {
        PersonalObservation(word: number, start3: number &+ 1, start4: number &+ 2, language: language)
    }

    /// Five confirmations on three days: the word is accepted on the last.
    private func teach(_ store: PersonalLexiconStore, _ desk: Desk, word: UInt64, generation: UInt32 = 0) {
        for _ in 0..<5 {
            store.record(PersonalTally(observations: [observation(word)], generation: generation))
            desk.day += 1
            desk.seconds += 31
        }
    }

    @Test func offReachesNoKeyAndNoFile() {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(false)
        #expect(!store.isActive)
        #expect(store.unavailable == nil)
        #expect(store.lexicon == .off)
        #expect(desk.keys.created == 0)
        #expect(!desk.file.exists)
        #expect(desk.changes.isEmpty, "the tap's lexicon is off already: nothing to say")
        let room = store.record(PersonalTally(observations: [observation(1)], generation: 0))
        #expect(room.observations.isEmpty)
        #expect(!desk.file.exists, "off: a batch is not counted and nothing is written")
        store.flush()
        #expect(!desk.file.exists)
    }

    @Test func turningItOnMakesTheKeyAndTheTapGetAnEmptyLexiconThatObserves() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        #expect(store.isActive)
        #expect(desk.keys.created == 1)
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.isOn)
        #expect(!lexicon.hasWords)
        #expect(lexicon.key == (try desk.keys.load()))
        #expect(!desk.file.exists, "the file waits for the first batch")
    }

    @Test func anExistingKeyIsKept() throws {
        let key = try LexiconKeyGenerator.make()
        let desk = Desk(keys: MemoryLexiconKeyStore(key: key))
        let store = desk.store()
        store.setEnabled(true)
        #expect(desk.keys.created == 0)
        #expect(desk.changes.last?.key == key)
    }

    @Test func aWordIsAcceptedAfterFiveObservationsOnThreeDaysAndTheTapIsTold() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let before = desk.changes.count
        for step in 0..<5 {
            store.record(PersonalTally(observations: [observation(0x100)], generation: 0))
            desk.day += step == 1 || step == 3 ? 1 : 0
            let accepted = store.wordCount == 1
            #expect(accepted == (step == 4), "step \(step)")
        }
        #expect(desk.changes.count == before + 1, "the tap hears of the set of accepted words changing, once")
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.containsWord(0x100))
        #expect(lexicon.containsStart(0x101) && lexicon.containsStart(0x102))
        #expect(lexicon.languages == ["ru"])
        #expect(store.lexicon == lexicon)
    }

    @Test func aBatchThatChangesNothingIsNotAnnounced() {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let before = desk.changes.count
        store.record(PersonalTally(observations: [observation(5)], generation: 0))
        store.record(PersonalTally(observations: [observation(6)], generation: 0))
        #expect(desk.changes.count == before)
    }

    @Test func theBufferGoesBackEmptyWithRoomForABatch() {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        var batch = PersonalRoom().observations
        batch.append(observation(1))
        batch.append(observation(2))
        let tally = PersonalTally(observations: batch, generation: 0)
        let room = store.record(tally)
        #expect(room.observations.isEmpty)
        #expect(room.observations.capacity >= PersonalRoom().observations.capacity)
        // And the machine takes it: a buffer with less room, or one with words in it, it does not.
        #expect(PersonalRoom(emptied: [observation(1)]).observations.count == 1)
    }

    @Test func theBufferGoesBackWhateverBecameOfTheBatch() {
        let desk = Desk()
        let store = desk.store()
        let capacity = PersonalRoom().observations.capacity
        // Off, a batch of an older generation, and a batch the demo made.
        for counting in [true, false] {
            var batch = PersonalRoom().observations
            batch.append(observation(1))
            let room = store.record(PersonalTally(observations: batch, generation: 0), counting: counting)
            #expect(room.observations.isEmpty && room.observations.capacity >= capacity)
        }
        store.setEnabled(true)
        store.erase()
        var batch = PersonalRoom().observations
        batch.append(observation(2))
        let room = store.record(PersonalTally(observations: batch, generation: 0))
        #expect(room.observations.isEmpty && room.observations.capacity >= capacity, "dropped by the generation, returned all the same")
    }

    @Test func theDemoCountsNothing() {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teachWith(store, desk, counting: false)
        #expect(store.wordCount == 0)
        #expect(!desk.file.exists)
    }

    private func teachWith(_ store: PersonalLexiconStore, _ desk: Desk, counting: Bool) {
        for _ in 0..<5 {
            store.record(PersonalTally(observations: [observation(9)], generation: 0), counting: counting)
            desk.day += 1
        }
    }

    @Test func theFileIsWrittenAtOnceThenAtMostEveryThirtySeconds() throws {
        let desk = Desk()
        let store = desk.store(saveInterval: 30)
        store.setEnabled(true)
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        #expect(desk.file.exists, "the first write waits for nothing")
        let key = try #require(try desk.keys.load())
        #expect(desk.file.load(key: key).entries.count == 1)
        desk.seconds += 10
        store.record(PersonalTally(observations: [observation(2)], generation: 0))
        #expect(desk.file.load(key: key).entries.count == 1, "10 s later: held back")
        desk.seconds += 15
        store.record(PersonalTally(observations: [observation(3)], generation: 0))
        #expect(desk.file.load(key: key).entries.count == 1, "25 s later: still held back")
        store.flush()
        #expect(desk.file.load(key: key).entries.count == 3, "quit writes what is held back")
        desk.seconds += 31
        store.record(PersonalTally(observations: [observation(4)], generation: 0))
        #expect(desk.file.load(key: key).entries.count == 4, "30 s after the last write")
    }

    @Test func aHeldBackWriteHappensOnItsOwn() async throws {
        let desk = Desk()
        let store = desk.store(saveInterval: 0.2)
        store.setEnabled(true)
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        desk.seconds += 0.05
        store.record(PersonalTally(observations: [observation(2)], generation: 0))
        let key = try #require(try desk.keys.load())
        #expect(desk.file.load(key: key).entries.count == 1)
        // On its own, within the interval and a good margin for a busy machine.
        var written = 1
        for _ in 0..<200 where written == 1 {
            try await Task.sleep(for: .seconds(0.05))
            written = desk.file.load(key: key).entries.count
        }
        #expect(written == 2)
        withExtendedLifetime(store) {}
    }

    @Test func aNewStoreReadsWhatTheOldOneKept() throws {
        let desk = Desk()
        let first = desk.store()
        first.setEnabled(true)
        teach(first, desk, word: 0x200)
        first.flush()
        #expect(first.wordCount == 1)
        let second = desk.store()
        second.setEnabled(true)
        #expect(second.wordCount == 1)
        #expect(desk.changes.last?.containsWord(0x200) == true)
        #expect(desk.keys.created == 1, "the same key")
    }

    @Test func turningItOffGoesBackToAnEmptyLexiconAndKeepsTheFile() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0x300)
        store.setEnabled(false)
        #expect(desk.changes.last == .off)
        #expect(store.lexicon == .off)
        #expect(!store.isActive)
        #expect(desk.file.exists, "off is not «erase»")
        #expect(store.hasStored)
        let room = store.record(PersonalTally(observations: [observation(0x400)], generation: 0))
        #expect(room.observations.isEmpty)
        store.setEnabled(true)
        #expect(store.wordCount == 1, "on again: the words are back")
        #expect(desk.keys.created == 1)
    }

    @Test func eraseDeletesTheFileAndTheKeyAndAnOldBatchIsDropped() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0x500)
        let oldKey = try #require(try desk.keys.load())
        let old = try #require(desk.changes.last)
        #expect(store.wordCount == 1)
        store.erase()
        #expect(store.wordCount == 0)
        #expect(!desk.file.exists)
        let newKey = try #require(try desk.keys.load(), "on: it goes on under a new key")
        #expect(newKey != oldKey)
        let fresh = try #require(desk.changes.last)
        #expect(fresh.generation == old.generation &+ 1)
        #expect(fresh.key == newKey && !fresh.hasWords)
        // A batch the tap counted under the old snapshot comes in late.
        teach(store, desk, word: 0x500, generation: old.generation)
        #expect(store.wordCount == 0)
        #expect(!store.lexicon.containsWord(0x500))
        // One under the new generation counts.
        teach(store, desk, word: 0x500, generation: fresh.generation)
        #expect(store.wordCount == 1)
    }

    @Test func eraseWhileOffRemovesTheFileAndTheKey() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0x600)
        store.setEnabled(false)
        store.erase()
        #expect(!desk.file.exists)
        #expect(try desk.keys.load() == nil)
        #expect(!store.hasStored)
        #expect(store.lexicon == .off)
    }

    @Test func forgetDropsAnAcceptedWordAtOnceAndTheTapIsTold() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        let word = key.fingerprint(ofWord: "Дашка", language: "ru")
        teach(store, desk, word: word)
        #expect(store.lexicon.containsWord(word))
        #expect(store.forget(PersonalWordRef(text: "Дашка,", language: "ru")), "the marks around the word are not the word")
        #expect(!store.lexicon.containsWord(word))
        #expect(desk.changes.last?.containsWord(word) == false)
        #expect(store.wordCount == 0)
        #expect(!store.forget(PersonalWordRef(text: "Дашка", language: "ru")), "nothing left to forget")
    }

    @Test func forgetFindsAWordByItsTextWhateverItsCaseAndItsYo() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        teach(store, desk, word: key.fingerprint(ofWord: "артём", language: "ru"))
        #expect(store.forget(PersonalWordRef(text: "«Артем»", language: "ru")))
        #expect(store.wordCount == 0)
    }

    @Test func forgetInAnotherLanguageFindsNothing() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        teach(store, desk, word: key.fingerprint(ofWord: "dashka", language: "en"))
        #expect(!store.forget(PersonalWordRef(text: "dashka", language: "ru")))
        #expect(store.wordCount == 1)
    }

    @Test func forgetDropsACandidateWithoutTellingTheTap() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        let word = key.fingerprint(ofWord: "кандидат", language: "ru")
        store.record(PersonalTally(observations: [observation(word)], generation: 0))
        let before = desk.changes.count
        #expect(store.forget(PersonalWordRef(text: "кандидат", language: "ru")))
        #expect(desk.changes.count == before)
        store.flush()
        #expect(desk.file.load(key: key).entries.isEmpty)
    }

    @Test func forgetWithTheLexiconOffDoesNothing() {
        let desk = Desk()
        let store = desk.store()
        #expect(!store.forget(PersonalWordRef(text: "слово", language: "ru")))
    }

    @Test func aKeychainThatRefusesTurnsTheLexiconOffAndLeavesNoSpareKey() throws {
        let keys = MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25293))
        let desk = Desk(keys: keys)
        let store = desk.store()
        store.setEnabled(true)
        #expect(!store.isActive)
        #expect(store.unavailable == .keychain)
        #expect(store.lexicon == .off)
        #expect(desk.changes.isEmpty)
        let room = store.record(PersonalTally(observations: [observation(1)], generation: 0))
        #expect(room.observations.isEmpty)
        store.flush()
        #expect(!desk.file.exists, "no key: no file, and no key of another kind")
        #expect(!FileManager.default.fileExists(atPath: desk.directory.path), "nothing at all was written")
        // The keychain comes back: the next try works.
        keys.setFailure(nil)
        store.setEnabled(false)
        store.setEnabled(true)
        #expect(store.isActive && store.unavailable == nil)
    }

    @Test func aKeychainThatFailsOnEraseTurnsTheLexiconOff() throws {
        let keys = MemoryLexiconKeyStore()
        let desk = Desk(keys: keys)
        let store = desk.store()
        store.setEnabled(true)
        keys.setFailure(LexiconKeyFailure.status(-25293))
        store.erase()
        #expect(!store.isActive)
        #expect(store.unavailable == .keychain)
        #expect(desk.changes.last == .off)
    }

    @Test func aProfileThatForbidsItKeepsItOffAndRemovesWhatWasKept() throws {
        let desk = Desk()
        let first = desk.store()
        first.setEnabled(true)
        teach(first, desk, word: 0x700)
        first.flush()
        #expect(desk.file.exists)
        let store = desk.store()
        store.setEnabled(true, allowed: false)
        #expect(!store.isActive)
        #expect(store.unavailable == .managed)
        #expect(!desk.file.exists)
        #expect(try desk.keys.load() == nil)
        #expect(!store.hasStored)
        #expect(desk.keys.created == 1, "no key is made under a profile")
    }

    @Test func aProfileThatForbidsItIsNoErrorWhenTheUserNeverAskedForIt() {
        let keys = MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25293))
        let desk = Desk(keys: keys)
        let store = desk.store()
        store.setEnabled(false, allowed: false)
        #expect(store.unavailable == nil)
        #expect(!store.isActive)
    }

    @Test func theTypingRecordingBuildKeepsASessionKeyAndNoWords() throws {
        let realKey = try LexiconKeyGenerator.make()
        let desk = Desk(keys: MemoryLexiconKeyStore(key: realKey))
        let store = desk.store(sessionOnly: true)
        store.setEnabled(true)
        #expect(store.isActive)
        let lexicon = try #require(desk.changes.last)
        #expect(lexicon.isOn && !lexicon.hasWords, "the machine observes and finds nothing")
        #expect(lexicon.key != realKey, "the real key does not reach the recording")
        #expect(lexicon.key?.isZero == false)
        #expect(desk.keys.created == 0)
        teach(store, desk, word: 0x800)
        #expect(store.wordCount == 0)
        #expect(!store.lexicon.hasWords)
        #expect(desk.changes.allSatisfy { !$0.hasWords && $0.key != realKey })
        #expect(!store.forget(PersonalWordRef(text: "слово", language: "ru")))
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: desk.directory.path), "no file")
        #expect(!store.hasStored)
        store.erase()
        #expect(try desk.keys.load() == realKey, "erasing the session's lexicon leaves the real one alone")
        #expect(store.lexicon.generation == 1)
        let again = desk.store(sessionOnly: true)
        again.setEnabled(true)
        #expect(desk.changes.last?.key != lexicon.key, "a session key is drawn for each run")
    }

    @Test func daysInTheFutureComeBackToToday() throws {
        let desk = Desk()
        let first = desk.store()
        first.setEnabled(true)
        desk.day = 30_000
        teach(first, desk, word: 0x900)
        first.flush()
        // The clock was set back: the words were seen "tomorrow".
        desk.day = 20_000
        let second = desk.store()
        second.setEnabled(true)
        let key = try #require(try desk.keys.load())
        second.flush()
        let kept = desk.file.load(key: key)
        #expect(kept.entries.values.allSatisfy { $0.lastDay <= 20_000 })
        // And an observation on the next day counts as a new day.
        let word = try #require(kept.entries.keys.first)
        let before = try #require(kept.entries[word]).days
        desk.day += 1
        second.record(PersonalTally(observations: [observation(word)], generation: 0))
        second.flush()
        #expect(try #require(desk.file.load(key: key).entries[word]).days == before + 1)
    }

    @Test func aClockSetBackWhileRunningDoesNotFreezeTheDays() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        desk.day = 30_000
        store.record(PersonalTally(observations: [observation(0xA00)], generation: 0))
        desk.day = 20_000
        store.record(PersonalTally(observations: [observation(0xA00)], generation: 0))
        store.flush()
        let key = try #require(try desk.keys.load())
        let entry = try #require(desk.file.load(key: key).entries[0xA00])
        #expect(entry.count == 2)
        #expect(entry.lastDay == 20_000, "seen today, not on a day that has not come")
        #expect(entry.days == 1, "the day it was moved to is the day it is seen on")
    }

    @Test func oldCandidatesAndWordsGoWhenItStarts() throws {
        let desk = Desk()
        let first = desk.store()
        first.setEnabled(true)
        first.record(PersonalTally(observations: [observation(0xB00)], generation: 0))
        teach(first, desk, word: 0xB10)
        first.flush()
        // 61 days later: the candidate is gone; the word, which is a year, is not.
        desk.day += 61
        let second = desk.store()
        second.setEnabled(true)
        let key = try #require(try desk.keys.load())
        second.flush()
        let kept = desk.file.load(key: key)
        #expect(kept.entries[0xB00] == nil)
        #expect(kept.entries[0xB10]?.accepted == true)
        // 400 days later: the word is gone, and the tap hears of it.
        desk.day += 400
        let third = desk.store()
        let before = desk.changes.count
        third.setEnabled(true)
        #expect(third.wordCount == 0)
        #expect(desk.changes.count == before + 1)
        #expect(desk.changes.last?.hasWords == false)
    }

    @Test func theCoreOfAWordIsItsLettersWithoutTheMarksAroundThem() {
        #expect(PersonalLexiconStore.core(of: "Дашка,") == "Дашка")
        #expect(PersonalLexiconStore.core(of: "«Дашка»") == "Дашка")
        #expect(PersonalLexiconStore.core(of: "(dashka).") == "dashka")
        #expect(PersonalLexiconStore.core(of: "dash-ka") == "dash-ka")
        #expect(PersonalLexiconStore.core(of: ",.") == "")
    }

    // MARK: - After the review of the first L2b

    @Test func aProfileThatForbidsItWritesNothingEvenWhenAWordWasHeldBackWithNoFirstWrite() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        try desk.block()
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        try desk.unblock()
        #expect(!desk.file.exists, "the first write failed: the word waits in memory")
        store.setEnabled(true, allowed: false)
        #expect(!desk.file.exists, "a profile forbids it: not a byte of the word's fingerprint is written")
        #expect(try desk.keys.load() == nil)
        #expect(!store.hasStored)
        #expect(store.unavailable == .managed)
    }

    @Test func aProfileThatForbidsItRemovesALoneKey() throws {
        let desk = Desk(keys: MemoryLexiconKeyStore(key: try LexiconKeyGenerator.make()))
        let store = desk.store()
        store.setEnabled(false, allowed: false)
        #expect(try desk.keys.load() == nil, "a key with no file is stored too")
        #expect(store.unavailable == nil, "the user never asked: no message")
        #expect(store.forbidden)
    }

    @Test func theProfileIsTheStoresAndNobodyElseReadsIt() {
        let forbidden = Desk().store(allowed: false)
        #expect(forbidden.forbidden && forbidden.unavailable == nil)
        forbidden.apply(true)
        #expect(forbidden.forbidden && forbidden.unavailable == .managed && !forbidden.isActive)
        let allowed = Desk().store()
        allowed.apply(true)
        #expect(!allowed.forbidden && allowed.isActive)
    }

    @Test func theSettingGoesToTheStoreOnlyWhenItChanges() {
        let desk = Desk()
        let store = desk.store()
        store.apply(false)
        #expect(desk.keys.created == 0 && desk.changes.isEmpty)
        store.apply(true)
        store.apply(true)
        #expect(desk.keys.created == 1 && desk.changes.count == 1)
        store.apply(false)
        #expect(desk.changes.last == .off && !store.isActive)
    }

    @Test func aKeychainThatCameBackIsTriedAgainAndTheLexiconIsOn() throws {
        let keys = MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308))
        let desk = Desk(keys: keys)
        let store = desk.store()
        store.apply(true)
        #expect(!store.isActive && store.unavailable == .keychain)
        store.retryActivation()
        #expect(!store.isActive && store.unavailable == .keychain, "still refused: still off, no crash")
        keys.setFailure(nil)
        store.retryActivation()
        #expect(store.isActive && store.unavailable == nil)
        #expect(try #require(desk.changes.last).isOn)
        #expect(desk.keys.created == 1)
    }

    @Test func aRetryDoesNothingWhenTheUserDidNotAskOrAProfileForbids() {
        let keys = MemoryLexiconKeyStore()
        let off = Desk(keys: keys).store()
        off.apply(false)
        off.retryActivation()
        #expect(!off.isActive && keys.created == 0, "off: no key is made")
        let forbidden = Desk(keys: keys).store(allowed: false)
        forbidden.apply(true)
        forbidden.retryActivation()
        #expect(!forbidden.isActive && keys.created == 0)
    }

    @Test func aRetryOfAnActiveStoreChangesNothing() {
        let desk = Desk()
        let store = desk.store()
        store.apply(true)
        let before = desk.changes.count
        store.retryActivation()
        #expect(desk.changes.count == before && desk.keys.created == 1)
    }

    @Test func aKeyThatCannotBeDeletedIsStillThereAndThePaneIsTold() throws {
        let keys = MemoryLexiconKeyStore()
        let desk = Desk(keys: keys)
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0xC00)
        keys.setFailure(LexiconKeyFailure.status(-25293))
        store.erase()
        #expect(!desk.file.exists, "the file went")
        #expect(store.hasStored, "the key may be there still: «Erase» stays open")
        #expect(store.eraseFailed)
        keys.setFailure(nil)
        store.erase()
        #expect(!store.eraseFailed)
        #expect(!store.hasStored)
    }

    @Test func aFileThatCannotBeRemovedIsStillThereAndThePaneIsTold() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0xD00)
        store.flush()
        #expect(desk.file.exists)
        let path = desk.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        store.erase()
        #expect(desk.file.exists)
        #expect(store.hasStored && store.eraseFailed)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        store.erase()
        #expect(!desk.file.exists && !store.eraseFailed)
    }

    @Test func eraseOfAKeyAndFileThatWentLeavesNothingStored() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        teach(store, desk, word: 0xE00)
        store.setEnabled(false)
        store.erase()
        #expect(!store.hasStored && !store.eraseFailed)
    }

    @Test func forgetThenFlushLeavesTheWordOutOfTheFile() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        let word = key.fingerprint(ofWord: "Дашка", language: "ru")
        teach(store, desk, word: word)
        store.flush()
        #expect(desk.file.load(key: key).entries[word] != nil)
        #expect(store.forget(PersonalWordRef(text: "Дашка", language: "ru")))
        store.flush()
        #expect(desk.file.load(key: key).entries[word] == nil, "forgotten means gone from the disk, not from memory only")
        let text = try String(contentsOf: desk.file.url, encoding: .utf8)
        #expect(!text.contains(JSONFingerprint.hex(word)))
    }

    @Test func eraseWithAWriteHeldBackDoesNotBringTheFileBack() async throws {
        let desk = Desk()
        let timers = Timers()
        let store = desk.store(timers: timers)
        store.setEnabled(true)
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        desk.seconds += 1
        store.record(PersonalTally(observations: [observation(2)], generation: 0))
        await timers.settle()
        #expect(timers.delays.count == 1, "the second batch waits for a timer")
        store.erase()
        await timers.fire()
        desk.seconds += 100
        #expect(!desk.file.exists, "the held back write died with the erase")
        store.flush()
        #expect(!desk.file.exists)
    }

    @Test func turningItOffWithAWriteHeldBackWritesNothingNowOrLater() async throws {
        let desk = Desk()
        let timers = Timers()
        let store = desk.store(timers: timers)
        store.setEnabled(true)
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        let key = try #require(try desk.keys.load())
        let written = try Data(contentsOf: desk.file.url)
        desk.seconds += 1
        store.record(PersonalTally(observations: [observation(2)], generation: 0))
        await timers.settle()
        #expect(timers.delays.count == 1, "a write is waiting")
        store.setEnabled(false)
        await timers.fire()
        store.flush()
        #expect(try Data(contentsOf: desk.file.url) == written, "off: the file is as the last write left it")
        #expect(desk.file.load(key: key).entries.count == 1)
    }

    @Test func aFailedWriteIsTriedAgainByTheTimerNotOnlyByTheNextBatch() async throws {
        let desk = Desk()
        let timers = Timers()
        let store = desk.store(saveInterval: 30, timers: timers)
        store.setEnabled(true)
        try desk.block()
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        await timers.settle()
        #expect(!desk.file.exists, "nothing is on disk")
        #expect(timers.delays == [30], "the retry is one interval away")
        try desk.unblock()
        desk.seconds += 31
        await timers.fire()
        let key = try #require(try desk.keys.load())
        #expect(desk.file.load(key: key).entries.count == 1, "no new batch came: the timer wrote it")
        #expect(timers.delays.count == 1, "written: no more retries")
    }

    @Test func aWriteThatKeepsFailingKeepsTryingEveryInterval() async throws {
        let desk = Desk()
        let timers = Timers()
        let store = desk.store(saveInterval: 30, timers: timers)
        store.setEnabled(true)
        try desk.block()
        store.record(PersonalTally(observations: [observation(1)], generation: 0))
        await timers.settle()
        await timers.fire()
        await timers.fire()
        #expect(timers.delays == [30, 30, 30])
        withExtendedLifetime(store) {}
    }

    @Test func wordsExpireWhenTheDayChangesWhileRunningNotOnlyAtLaunch() throws {
        let desk = Desk()
        let store = desk.store()
        store.setEnabled(true)
        let key = try #require(try desk.keys.load())
        let old = key.fingerprint(ofWord: "староеслово", language: "ru")
        teach(store, desk, word: old)
        #expect(store.wordCount == 1)
        // The Mac sleeps for 400 days of the calendar; a batch comes in the morning.
        desk.day += 400
        store.record(PersonalTally(observations: [observation(0xF00)], generation: 0))
        #expect(store.wordCount == 0)
        #expect(!store.lexicon.containsWord(old))
        #expect(desk.changes.last?.containsWord(old) == false, "the tap hears of it")
        store.flush()
        #expect(desk.file.load(key: key).entries[old] == nil)
    }

    @Test func theSessionLexiconOfTheRecordingKeepsItsGenerationAcrossTheSwitch() throws {
        let desk = Desk()
        let store = desk.store(sessionOnly: true)
        store.setEnabled(true)
        #expect(store.lexicon.generation == 0)
        store.erase()
        #expect(store.lexicon.generation == 1)
        store.setEnabled(false)
        store.setEnabled(true)
        #expect(store.lexicon.generation == 1, "monotonic: not 0 again after the switch")
        store.erase()
        #expect(store.lexicon.generation == 2)
    }

    @Test func theSaveIntervalIsThirtySecondsAndTheKeyIsDrawnThreeTimesAtMost() {
        #expect(PersonalLexiconStore.defaultSaveInterval == 30)
        #expect(LexiconKeyGenerator.attempts == 3)
    }
}

/// The hex of a fingerprint as the file writes it.
private enum JSONFingerprint {
    static func hex(_ value: UInt64) -> String { PersonalLexiconFile.hex(value) }
}
