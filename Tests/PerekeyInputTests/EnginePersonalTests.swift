// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

/// The engine's two ends of the personal lexicon (docs/classifier.md, «Личный
/// словарь»): what the tap hands to the main thread and what it asks of it.
/// The engine runs here with no tap: `handle` and `execute` on the test thread,
/// the messages read on the main queue.
@MainActor
struct EnginePersonalTests {
    @MainActor private final class Inbox {
        var messages: [EngineMessage] = []
    }

    private func engine(_ inbox: Inbox) -> InputEngine {
        InputEngine(machine: InputMachine()) { message in inbox.messages.append(message) }
    }

    /// What was posted to the main queue before this point has run.
    private func drain() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private let lexicon = PersonalLexicon(key: PersonalKey(bytes: (1...16).map { UInt8($0) })!, words: [UInt64](), starts: [UInt64]())

    private func wanted(_ inbox: Inbox) -> [Int] {
        inbox.messages.compactMap { if case let .personalRoomsWanted(count) = $0 { count } else { nil } }
    }

    @Test func aNewLexiconAsksTheMainThreadForTwoBuffers() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        engine.handle(.personalLexiconChanged(lexicon))
        await drain()
        #expect(wanted(inbox) == [2])
    }

    @Test func buffersThatCameBackAreNotAskedForAgain() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        engine.handle(.personalLexiconChanged(lexicon))
        engine.handle(.personalRoomReturned(PersonalRoom()))
        engine.handle(.personalRoomReturned(PersonalRoom()))
        // The set of words changed: a new snapshot, the same buffers.
        let next = PersonalLexicon(key: PersonalKey(bytes: (1...16).map { UInt8($0) })!, words: [1, 2, 3], starts: [4, 5])
        engine.handle(.personalLexiconChanged(next))
        await drain()
        #expect(wanted(inbox) == [2], "the second snapshot found the machine full")
    }

    @Test func oneBufferBackIsOneStillWanted() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        engine.handle(.personalLexiconChanged(lexicon))
        engine.handle(.personalRoomReturned(PersonalRoom()))
        let next = PersonalLexicon(key: PersonalKey(bytes: (1...16).map { UInt8($0) })!, words: [1], starts: [2])
        engine.handle(.personalLexiconChanged(next))
        await drain()
        #expect(wanted(inbox) == [2, 1])
    }

    @Test func offAsksForNothing() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        engine.handle(.personalLexiconChanged(.off))
        await drain()
        #expect(wanted(inbox).isEmpty)
    }

    @Test func turnedOffAndOnAgainAsksForTwoAgain() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        engine.handle(.personalLexiconChanged(lexicon))
        engine.handle(.personalRoomReturned(PersonalRoom()))
        engine.handle(.personalRoomReturned(PersonalRoom()))
        engine.handle(.personalLexiconChanged(.off))
        engine.handle(.personalLexiconChanged(lexicon))
        await drain()
        #expect(wanted(inbox) == [2, 2], "off lets go of the buffers")
    }

    @Test func theWordsAKeyboardKeptReachTheMainThread() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        let tally = PersonalTally(
            observations: [PersonalObservation(word: 7, start3: 8, start4: nil, language: "ru")], generation: 3)
        engine.execute([.wordsKept(tally)])
        await drain()
        let received = inbox.messages.compactMap { message -> PersonalTally? in
            if case let .wordsKept(tally) = message { tally } else { nil }
        }
        #expect(received == [tally])
    }

    @Test func aStoreAndTheEngineMakeTheWholeRoundTrip() async throws {
        // The path of docs/classifier.md: tap → engine → store → room back to the tap.
        let inbox = Inbox()
        let engine = engine(inbox)
        let keys = MemoryLexiconKeyStore()
        let store = PersonalLexiconStore(file: nil, keys: keys, today: { 20_000 })
        store.onLexiconChanged = { engine.handle(.personalLexiconChanged($0)) }
        store.setEnabled(true)
        await drain()
        #expect(wanted(inbox) == [2])
        for count in wanted(inbox) { for _ in 0..<count { engine.handle(.personalRoomReturned(PersonalRoom())) } }
        var batch = PersonalRoom().observations
        batch.append(PersonalObservation(word: 1, start3: 2, start4: 3, language: "ru"))
        engine.execute([.wordsKept(PersonalTally(observations: batch, generation: 0))])
        await drain()
        let tally = try #require(inbox.messages.compactMap { message -> PersonalTally? in
            if case let .wordsKept(tally) = message { tally } else { nil }
        }.first)
        engine.handle(.personalRoomReturned(store.record(tally)))
        // The machine is full again: a new lexicon asks for nothing.
        store.erase()
        await drain()
        #expect(wanted(inbox) == [2])
    }

    private func released(_ inbox: Inbox) -> [PersonalLexicon] {
        inbox.messages.compactMap { if case let .personalLexiconReleased(old) = $0 { old } else { nil } }
    }

    @Test func theOldLexiconGoesToTheMainThreadWhenANewOneComesIn() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        let next = PersonalLexicon(key: PersonalKey(bytes: (1...16).map { UInt8($0) })!, words: [1, 2], starts: [3])
        engine.handle(.personalLexiconChanged(lexicon))
        await drain()
        #expect(released(inbox).isEmpty, "off before it: nothing to let go of")
        engine.handle(.personalLexiconChanged(next))
        await drain()
        #expect(released(inbox) == [lexicon], "the first snapshot is freed on the main thread")
        engine.handle(.personalLexiconChanged(.off))
        await drain()
        #expect(released(inbox) == [lexicon, next])
        engine.handle(.personalLexiconChanged(.off))
        await drain()
        #expect(released(inbox).count == 2, "off for off: no message")
    }

    @Test func theLexiconAMessageHoldsIsTheOneTheTapLetGo() async {
        let inbox = Inbox()
        let engine = engine(inbox)
        let next = PersonalLexicon(key: PersonalKey(bytes: (1...16).map { UInt8($0) })!, words: [9], starts: [])
        engine.handle(.personalLexiconChanged(lexicon))
        engine.handle(.personalLexiconChanged(next))
        await drain()
        #expect(released(inbox).first?.words == lexicon.words)
        #expect(engine.personalLexicon.words == [9], "the machine has the new one")
    }

    // MARK: - The setting, the profile and the tap

    private func wired(_ engine: InputEngine, allowed: Bool, keys: MemoryLexiconKeyStore = MemoryLexiconKeyStore())
        -> PersonalLexiconStore
    {
        let store = PersonalLexiconStore(file: nil, keys: keys, today: { 20_000 }, allowed: allowed)
        store.onLexiconChanged = { engine.handle(.personalLexiconChanged($0)) }
        return store
    }

    @Test func theSettingOnGivesTheTapAnEmptyLexiconWithTheKeyAndOffTakesItBack() throws {
        let inbox = Inbox()
        let engine = engine(inbox)
        let keys = MemoryLexiconKeyStore()
        let store = wired(engine, allowed: true, keys: keys)
        #expect(!engine.personalLexicon.isOn, "before the setting is applied: off")
        store.apply(false)
        #expect(!engine.personalLexicon.isOn, "off from the start: the tap has nothing, no key was asked for")
        #expect(keys.created == 0)
        store.apply(true)
        #expect(engine.personalLexicon.isOn && !engine.personalLexicon.hasWords)
        #expect(engine.personalLexicon.key == (try keys.load()))
        store.apply(false)
        #expect(engine.personalLexicon == .off)
    }

    @Test func aProfileThatForbidsItLeavesTheTapOffWhateverTheSetting() {
        let inbox = Inbox()
        let engine = engine(inbox)
        let keys = MemoryLexiconKeyStore()
        let store = wired(engine, allowed: false, keys: keys)
        store.apply(true)
        #expect(engine.personalLexicon == .off)
        #expect(keys.created == 0)
        store.apply(false)
        store.apply(true)
        #expect(engine.personalLexicon == .off)
    }

    @Test func aKeychainBackAfterTheLaunchTurnsTheTapOn() throws {
        let inbox = Inbox()
        let engine = engine(inbox)
        let keys = MemoryLexiconKeyStore(failure: LexiconKeyFailure.status(-25308))
        let store = wired(engine, allowed: true, keys: keys)
        store.apply(true)
        #expect(engine.personalLexicon == .off)
        keys.setFailure(nil)
        store.retryActivation()
        #expect(engine.personalLexicon.isOn)
    }
}
