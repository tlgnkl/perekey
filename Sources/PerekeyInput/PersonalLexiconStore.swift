// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os
import PerekeyCore

/// A word of the personal lexicon as the main thread knows it for a moment:
/// its text, in the hint or the menu, and its language. It is never stored,
/// and it prints as `<redacted>`: the text must not reach a log or a crash
/// report, as the key's does not.
public struct PersonalWordRef: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public var text: String
    public var language: LanguageCode

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public init(text: String, language: LanguageCode) {
        self.text = text
        self.language = language
    }

    /// The word a correction switched to, when it switched to it because the
    /// personal lexicon has it (`Classifier.Decision.otherPersonal`).
    public init?(switchedTo correction: Correction) {
        guard let decision = correction.decision, decision.otherPersonal, let name = decision.otherLanguage,
              let language = LanguageCode(name)
        else { return nil }
        self.init(text: correction.replacement, language: language)
    }

    /// The word the user typed and then retyped by hand into another layout,
    /// when it was in the personal lexicon (`Classifier.Decision.typedPersonal`).
    public init?(retyped original: String, decision: Classifier.Decision?) {
        guard let decision, decision.typedPersonal, let name = decision.typedLanguage,
              let language = LanguageCode(name)
        else { return nil }
        self.init(text: original, language: language)
    }
}

/// The main thread's side of the strong signals against a personal word
/// (docs/classifier.md, «Личный словарь»): the undo of a switch to it, by the
/// hint's button, by the shortcut or by a Backspace that settled as «keep it
/// as typed», and a retype of it by hand into another layout. Each says the
/// word is not the user's after all, and the lexicon drops it at once. It
/// holds the text of words for a moment and prints as `<redacted>`.
public struct PersonalSignals: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// The switches to a personal word that still stand, by `Correction.seq`.
    private var switches: [(seq: UInt32, word: PersonalWordRef)] = []
    /// The word of an undo that is not settled yet.
    private var undone: PersonalWordRef?

    /// How many switches are remembered: the hint offers an undo for the
    /// newest one only, and the menu's few rows are older than that.
    static let remembered = 8

    public init() {}

    /// A switch was posted.
    public mutating func corrected(_ correction: Correction) {
        guard let word = PersonalWordRef(switchedTo: correction) else { return }
        switches.append((correction.seq, word))
        if switches.count > Self.remembered { switches.removeFirst() }
    }

    /// The switch with this `seq` was undone; whether the undo counts is
    /// known once it settles (`settled`).
    public mutating func undone(seq: UInt32) {
        guard let index = switches.lastIndex(where: { $0.seq == seq }) else {
            undone = nil
            return
        }
        undone = switches.remove(at: index).word
    }

    /// The undo settled. The word to drop, if it was the undo of a switch to
    /// a personal word and meant «keep it as typed»: the button and the
    /// shortcut always mean it, a Backspace only when the user typed on with
    /// the word as typed (`UndoFollowUp.continued`).
    public mutating func settled(_ report: UndoReport) -> PersonalWordRef? {
        defer { undone = nil }
        guard let word = undone else { return nil }
        switch report.channel {
        case .button, .shortcut: return word
        case .backspace: return report.followUp == .continued ? word : nil
        }
    }
}

/// The personal lexicon in memory, on the main thread: it takes the batches
/// the tap counted, runs `PersonalLexiconModel`, keeps the file and the key,
/// and tells the tap when the set of accepted words changes. The settings
/// switch «Мои слова» is the only way in: off, the store reaches no key and
/// no file, observes nothing and the snapshot is empty.
///
/// The path is the one of the language counts (`LanguageStatsStore`):
/// `Effect.wordsKept` → `InputEngine` → `record` → `onLexiconChanged` →
/// `InputEvent.personalLexiconChanged`; the generation drops a batch counted
/// before an erase. Text is in memory for a moment only: `forget` takes the
/// word's text and keeps nothing of it.
@MainActor
@Observable
public final class PersonalLexiconStore {
    /// Why the lexicon is off though the user asked for it.
    public enum Unavailable: Hashable, Sendable {
        /// A profile forbids it (`ManagedSettings.personalWordsDisabled`).
        case managed
        /// The Keychain does not give the key, and there is no spare one.
        case keychain
    }

    /// The user asked for the lexicon and nothing stands in the way.
    public private(set) var isActive = false
    public private(set) var unavailable: Unavailable?
    /// Accepted words, for the privacy pane.
    public private(set) var wordCount = 0
    /// Something of the lexicon is on disk or in the Keychain: the pane offers «Erase».
    public private(set) var hasStored = false
    /// A profile forbids the lexicon (`ManagedSettings.personalWordsDisabled`),
    /// whether the user asked for it or not. The one place that says so: the
    /// pane reads it here, not from the profile.
    public private(set) var forbidden = false
    /// The last erase left the file or the key behind and they are there still:
    /// the pane says so. It follows the facts: a new key, a write that worked
    /// or an erase that finds nothing left clear it, not only the next erase.
    public var eraseFailed: Bool { (fileLeft || keyLeft) && hasStored }
    private var fileLeft = false
    private var keyLeft = false
    /// The lexicon the tap has now.
    @ObservationIgnored public private(set) var lexicon = PersonalLexicon.off

    /// Called when the snapshot for the tap changes: the set of accepted
    /// words, the key or the generation.
    @ObservationIgnored public var onLexiconChanged: (@MainActor (PersonalLexicon) -> Void)?

    @ObservationIgnored private let file: PersonalLexiconFile?
    @ObservationIgnored private let keys: any LexiconKeyStore
    @ObservationIgnored private let options: PersonalOptions
    @ObservationIgnored private let saveInterval: Double
    @ObservationIgnored private let sleep: @Sendable (Double) async -> Void
    @ObservationIgnored private let today: @MainActor () -> Int
    @ObservationIgnored private let clock: @MainActor () -> Double
    @ObservationIgnored private let sessionOnly: Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "lexicon")

    /// What the user asked for and what the profile allows, as the store last heard.
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var permitted: Bool
    @ObservationIgnored private var applied: Bool?
    @ObservationIgnored private var key: PersonalKey? {
        didSet { buildShared() }
    }
    /// The words other settings name as the user's own (the right side of the
    /// voice dictionary), as text, for a moment longer than a word's text
    /// stays elsewhere: they are the user's own settings, already in
    /// `voice-text.json`, and a new key (an erase) needs them again. They are
    /// never written by the store.
    /// `deactivate` leaves them: the lexicon off keeps no fingerprint, but the
    /// text of a dictionary record is the user's own and is in `voice-text.json`.
    @ObservationIgnored private var sharedTexts: [String] = []
    /// Their identities (`PersonalKey.sharedIdentity(ofWord:)`), no key needed.
    @ObservationIgnored private var sharedIdentities: Set<String> = []
    /// The shared words a confirmed undo or a retype by hand said were not the
    /// user's after all, by identity. A strong signal against a shared word has
    /// no entry to drop, so the word is kept out of the snapshot until the app
    /// quits or its record in the dictionary changes (`setSharedWords`). In
    /// memory only: nothing of it is written, and a new run starts without it.
    @ObservationIgnored private var suppressed: Set<String> = []
    /// Every shared word with its fingerprints under the key now, the suppressed ones too; empty
    /// while there is no key. Built once for a list and a key (`buildShared`): a signal only
    /// filters it, so it hashes nothing on the path of the input.
    @ObservationIgnored private var sharedEntries: [PersonalKey.SharedEntry] = []
    /// The fingerprints of the words in `sharedEntries` that are not suppressed: the snapshot's part.
    @ObservationIgnored private var shared: [PersonalObservation] = []
    /// The fingerprints of every shared word, the suppressed ones too: the dictionary has them, `forget` says so.
    @ObservationIgnored private var sharedWords: Set<UInt64> = []
    /// The fingerprints of the shared words not suppressed: no batch counts these. A suppressed word is
    /// counted like any other, so the user can teach it again before the app restarts.
    @ObservationIgnored private var liveSharedWords: Set<UInt64> = []
    /// How many times the fingerprints were built (the list cut, hashed): the tests' seam for the cost of a signal.
    @ObservationIgnored private(set) var sharedFingerprintBuilds = 0
    @ObservationIgnored private var model: PersonalLexiconModel
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastSave: Double?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The folder's leftovers of a crash are swept once per run, before the first write.
    @ObservationIgnored private var swept = false
    /// The latest day a batch was counted on: a clock set back shows as a day before it.
    @ObservationIgnored private var latestDay = Int.min

    /// The file is written at most this often, in seconds, and when `flush`
    /// says so (quit); a write that failed is tried again after as long.
    /// 30 s: a word is counted every few seconds of typing, a full write is
    /// all the entries, and a quit loses nothing (docs/classifier.md,
    /// «Личный словарь», «Файл»; step L2b, point 2 of the plan).
    public static let defaultSaveInterval = 30.0

    /// - Parameters:
    ///   - file: nil keeps nothing on disk (snapshots).
    ///   - saveInterval: see `defaultSaveInterval`.
    ///   - today: the calendar day, as the app numbers days.
    ///   - allowed: false under a profile that forbids the lexicon
    ///     (`ManagedSettings.personalWordsDisabled`, read once, at launch).
    ///   - sleep: waits for the held back write; the tests run it by hand. Not main-actor: a task
    ///     that awaits a main-actor closure trips a Swift runtime check in the CI toolchain.
    ///   - sessionOnly: the typing recording's build (`PEREKEY_RECORD`): the
    ///     store draws a key of its own for the run, in memory, reads no
    ///     keychain and no file, and keeps no word. The machine observes
    ///     under the session key and finds nothing, so the recording holds
    ///     the session key and the fingerprints of the words under it
    ///     (`wordsKept`, `personalLexiconChanged`); it holds neither the real
    ///     key nor a fingerprint that works on the user's file. The text of
    ///     the typing is in the recording anyway.
    public init(file: PersonalLexiconFile? = PersonalLexiconFile(), keys: any LexiconKeyStore,
                options: PersonalOptions = PersonalOptions(), saveInterval: Double = PersonalLexiconStore.defaultSaveInterval,
                today: @escaping @MainActor () -> Int, allowed: Bool = true, sessionOnly: Bool = false,
                clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) })
    {
        permitted = allowed
        forbidden = !allowed
        self.sleep = sleep
        self.file = file
        self.keys = keys
        self.options = options
        self.saveInterval = saveInterval
        self.today = today
        self.sessionOnly = sessionOnly
        self.clock = clock
        model = PersonalLexiconModel(options: options)
        hasStored = !sessionOnly && file?.exists == true
    }

    // MARK: - The switch

    /// The setting «Мои слова» as the settings hold it: the store hears of a
    /// change only. The profile is the one the store was made with.
    public func apply(_ wanted: Bool) {
        guard wanted != applied else { return }
        applied = wanted
        setEnabled(wanted, allowed: permitted)
    }

    /// Applies the setting «Мои слова». `allowed` is false under a profile
    /// that forbids the lexicon: then nothing is read or kept, nothing is
    /// written, and what an earlier run left on disk and in the Keychain goes.
    public func setEnabled(_ wanted: Bool, allowed: Bool = true) {
        self.wanted = wanted
        permitted = allowed
        forbidden = !allowed
        if !allowed {
            dropHeldBackWrite()
            // Only for something stored: a profile that forbids the lexicon
            // asks the Keychain for nothing on a Mac that never had it.
            // (A key made and never followed by a file, by an earlier run, stays: it hides nothing.)
            if hasStored { eraseStorage() }
            deactivate(unavailable: wanted ? .managed : nil)
            return
        }
        guard wanted else {
            deactivate(unavailable: nil)
            return
        }
        guard !isActive else { return }
        activate()
    }

    // MARK: - Shared words

    /// The words the voice dictionary names as the user's own, as the
    /// dictionary holds them now (the right side of each record). With the
    /// lexicon on they are accepted words from this moment: the tap hears of
    /// them in the snapshot, once, and a record that goes leaves the next
    /// snapshot. Off, they are kept for when it is on and the tap hears of
    /// nothing (docs/classifier.md, «Общие слова»).
    ///
    /// The fingerprints are made here, on the main thread, under the key of
    /// the lexicon. They are no entry of the model: they are counted by no
    /// batch and written to no file.
    public func setSharedWords(_ texts: [String]) {
        guard texts != sharedTexts else { return }
        sharedTexts = texts
        // A record that changed is a new word of the user's: the word it names is not suppressed any more.
        // A word in the old list and in the new one has the record it had.
        let identities = PersonalKey.sharedIdentities(of: texts, options: options)
        suppressed.formIntersection(sharedIdentities.intersection(identities))
        sharedIdentities = identities
        buildShared()
        if isActive { publish() }
    }

    /// Cuts and hashes the list under the key: for a new list and for a new key, and for nothing else.
    private func buildShared() {
        guard let key else {
            sharedEntries = []
            sharedWords = []
            filterShared()
            return
        }
        sharedFingerprintBuilds += 1
        sharedEntries = key.sharedEntries(of: sharedTexts, options: options)
        sharedWords = Set(sharedEntries.lazy.flatMap(\.observations).map(\.word))
        filterShared()
    }

    /// The part of the built list that is not suppressed. No text is cut and nothing is hashed.
    private func filterShared() {
        shared = suppressed.isEmpty
            ? sharedEntries.flatMap(\.observations)
            : sharedEntries.filter { !suppressed.contains($0.identity) }.flatMap(\.observations)
        liveSharedWords = suppressed.isEmpty ? sharedWords : Set(shared.lazy.map(\.word))
    }

    /// The Keychain refused the key when the lexicon was asked for (a locked
    /// login keychain, `errSecInteractionNotAllowed`): try again. The app
    /// calls this when it is activated and when the pane opens. It does
    /// nothing unless the user asked, no profile forbids it and the Keychain
    /// was the reason.
    public func retryActivation() {
        guard wanted, permitted, !isActive, unavailable == .keychain else { return }
        activate()
    }

    private func activate() {
        if sessionOnly {
            guard let session = try? LexiconKeyGenerator.make() else {
                return deactivate(unavailable: .keychain)
            }
            key = session
            // The generation only goes up over the run (an erase raises it): a switch off and on is not a start at 0.
            model = PersonalLexiconModel(options: options, generation: model.generation)
            finishActivation()
            return
        }
        let loaded: PersonalKey
        do {
            loaded = try keys.load() ?? keys.create()
        } catch {
            log.error("The key of the personal lexicon is not available: \(String(describing: error), privacy: .private)")
            return deactivate(unavailable: .keychain)
        }
        key = loaded
        hasStored = true
        keyLeft = false
        var counted = file?.load(key: loaded, options: options, generation: model.generation)
            ?? PersonalLexiconModel(options: options, generation: model.generation)
        let day = today()
        var changed = Self.clampFuture(&counted, to: day)
        // A candidate that expires is not a change of the accepted set, but the file has it still.
        let before = counted.entries.count
        if counted.expire(today: day) || counted.entries.count != before { changed = true }
        model = counted
        finishActivation()
        if changed { markDirty() }
    }

    private func finishActivation() {
        isActive = true
        unavailable = nil
        publish()
    }

    /// Off writes nothing: what was held back goes with the switch. The file
    /// is as the last write left it (the lexicon is not erased by turning it off).
    private func deactivate(unavailable reason: Unavailable?) {
        dropHeldBackWrite()
        isActive = false
        unavailable = reason
        key = nil
        wordCount = 0
        // Off keeps no fingerprint in memory; on reads the file again. The texts of the
        // shared words stay (`sharedTexts`): they are in `voice-text.json` anyway.
        model = PersonalLexiconModel(options: options, generation: model.generation)
        guard lexicon.isOn else { return }
        lexicon = .off
        onLexiconChanged?(.off)
    }

    // MARK: - Counting

    /// Counts a batch of the tap and gives its buffer back, emptied, for the
    /// tap's next batch (`InputEvent.personalRoomReturned`). The room goes
    /// back whatever happened to the batch (`counting: false` counts nothing): a store that is off or a batch of
    /// an older generation must not leave the tap without a buffer.
    @discardableResult
    public func record(_ tally: PersonalTally, counting: Bool = true) -> PersonalRoom {
        if counting, isActive, !sessionOnly { count(tally) }
        // The array may be shared with the message that brought it: then this
        // makes a new one of the same capacity, on the main thread.
        var buffer = tally.observations
        buffer.removeAll(keepingCapacity: true)
        return PersonalRoom(emptied: buffer)
    }

    private func count(_ tally: PersonalTally) {
        let day = today()
        if day < latestDay {
            Self.clampFuture(&model, to: day)
        } else if latestDay != .min, day > latestDay, model.expire(today: day) {
            // A word or a candidate ran out while the app was running, not at the start.
            publish()
        }
        latestDay = day
        let acceptedChanged = model.record(withoutShared(tally), day: day)
        if acceptedChanged { publish() }
        markDirty()
    }

    /// A shared word is accepted without counting. One the model counts already
    /// (the user taught it before the dictionary named it) goes on counting, so it
    /// does not run out under the dictionary and stays when the record goes.
    private func withoutShared(_ tally: PersonalTally) -> PersonalTally {
        guard !liveSharedWords.isEmpty else { return tally }
        var kept = tally
        kept.observations = tally.observations.filter { !liveSharedWords.contains($0.word) || model.entries[$0.word] != nil }
        return kept
    }

    /// What «Забыть слово» did.
    public enum ForgetResult: Hashable, Sendable {
        /// The word was the set's own and is gone.
        case forgotten
        /// The word is in the voice dictionary, which this does not touch: the
        /// record has to be deleted there. (An entry the set had for it is gone.)
        case sharedWord
        /// The lexicon does not have the word.
        case notInLexicon
    }

    /// Drops the word the user asked to forget («Забыть слово» in the hint or
    /// the menu). A word of the voice dictionary stays while its record does:
    /// the answer says so, for the hint and the menu to tell the user where to
    /// delete it.
    @discardableResult
    public func forget(_ word: PersonalWordRef) -> ForgetResult {
        let (result, acceptedChanged) = dropEntry(word)
        if acceptedChanged { publish() }
        return result
    }

    /// The model's part of `forget`: the entry dropped and the file marked, the snapshot left to the caller.
    private func dropEntry(_ word: PersonalWordRef) -> (result: ForgetResult, acceptedChanged: Bool) {
        guard isActive, !sessionOnly, let key else { return (.notInLexicon, false) }
        let fingerprint = key.fingerprint(ofWord: Self.core(of: word.text), language: word.language)
        let before = model.entries.count
        let acceptedChanged = model.forget(fingerprint)
        let dropped = model.entries.count != before
        if dropped { markDirty() }
        if sharedWords.contains(fingerprint) { return (.sharedWord, acceptedChanged && dropped) }
        return (dropped ? .forgotten : .notInLexicon, acceptedChanged && dropped)
    }

    /// A strong signal against the word: a confirmed undo of the switch to it,
    /// or a retype of it by hand. The set's entry is dropped at once, as by
    /// `forget`. A word of the voice dictionary has no entry, so it is kept
    /// out of the snapshot for the session, from the first signal, until the
    /// app quits or its record changes; the dictionary itself is not touched.
    /// Nothing of this is written to disk. The signal comes on the path of the
    /// input: it filters the list built before and hashes nothing, and the
    /// snapshot goes out once.
    public func withdraw(_ word: PersonalWordRef) {
        guard isActive, !sessionOnly else { return }
        let (result, acceptedChanged) = dropEntry(word)
        var changed = acceptedChanged
        if result == .sharedWord {
            let identity = PersonalKey.sharedIdentity(ofWord: word.text)
            if sharedIdentities.contains(identity), suppressed.insert(identity).inserted {
                filterShared()
                changed = true
            }
        }
        if changed { publish() }
    }

    /// «Стереть»: deletes the file and the key and starts a new generation,
    /// so the batches counted before are dropped. With the lexicon on it
    /// goes on empty under a new key.
    public func erase() {
        dropHeldBackWrite()
        model.erase()
        wordCount = 0
        eraseStorage()
        guard isActive else { return }
        if sessionOnly {
            publish()
            return
        }
        do {
            key = try keys.create()
            hasStored = true
            keyLeft = false
        } catch {
            log.error("The key of the personal lexicon is not available: \(String(describing: error), privacy: .private)")
            deactivate(unavailable: .keychain)
            return
        }
        publish()
    }

    /// Removes the file and the key, with no condition: a key without a file
    /// is stored too. What is left is told by `hasStored` and `eraseFailed`.
    private func eraseStorage() {
        guard !sessionOnly else { return }
        var fileFailed = false
        var keyFailed = false
        do { try file?.remove() } catch {
            fileFailed = true
            log.error("The file of the personal lexicon is not removed: \(error.localizedDescription, privacy: .private)")
        }
        do { try keys.delete() } catch {
            keyFailed = true
            log.error("The key of the personal lexicon is not removed: \(String(describing: error), privacy: .private)")
        }
        fileLeft = fileFailed
        keyLeft = keyFailed
        hasStored = keyFailed || file?.exists == true
    }

    // MARK: - The snapshot

    private func publish() {
        guard let key else { return }
        wordCount = model.acceptedCount
        let snapshot = sessionOnly
            ? PersonalLexicon(key: key, words: [UInt64](), starts: [UInt64](), generation: model.generation, options: options)
            : model.snapshot(key: key, shared: shared)
        guard snapshot != lexicon else { return }
        lexicon = snapshot
        onLexiconChanged?(snapshot)
    }

    // MARK: - The file

    /// Writes at once when the last write is `saveInterval` back, else later.
    private func markDirty() {
        dirty = true
        guard !sessionOnly, file != nil, saveTask == nil else { return }
        let waited = lastSave.map { clock() - $0 } ?? saveInterval
        if waited >= saveInterval {
            saveNow()
            return
        }
        schedule(after: saveInterval - waited)
    }

    private func schedule(after delay: Double) {
        guard saveTask == nil else { return }
        let sleep = sleep
        saveTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            saveNow()
        }
    }

    /// Writes what is not written (quit).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    /// What is held back is dropped, with its timer: an erase, the switch
    /// off and a profile that forbids the lexicon write nothing.
    private func dropHeldBackWrite() {
        saveTask?.cancel()
        saveTask = nil
        dirty = false
    }

    private func saveNow() {
        guard dirty, !sessionOnly, let file, let key else { return }
        dirty = false
        lastSave = clock()
        if !swept {
            file.sweepTemporaries()
            swept = true
        }
        do {
            try file.save(model, key: key)
            hasStored = true
            fileLeft = false
        } catch {
            dirty = true
            log.error("The personal lexicon is not saved: \(error.localizedDescription, privacy: .private)")
            // Not only the next batch tries again: a disk that is full or a folder that is locked may stay so while the user types nothing.
            schedule(after: saveInterval)
        }
    }

    // MARK: - For the tests

    var heldBackWrite: Task<Void, Never>? { saveTask }
    var heldEntryCount: Int { model.entries.count }

    // MARK: - Helpers

    /// The core of a word as the fingerprint takes it: the letters, without
    /// the marks around them ("Дашка," → "Дашка"; `Reading.coreStart`).
    static func core(of text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard let first = scalars.firstIndex(where: { $0.properties.isAlphabetic }),
              let last = scalars.lastIndex(where: { $0.properties.isAlphabetic })
        else { return "" }
        var core = String.UnicodeScalarView()
        core.append(contentsOf: scalars[first...last])
        return String(core)
    }

    /// A clock set back leaves entries seen «tomorrow»: new observations
    /// would not count as a new day, and the lifetime would not run out.
    /// They are moved to today. Returns whether any moved.
    @discardableResult
    static func clampFuture(_ model: inout PersonalLexiconModel, to day: Int) -> Bool {
        guard model.entries.values.contains(where: { $0.lastDay > day }) else { return false }
        var entries = model.entries
        for (fingerprint, var entry) in entries where entry.lastDay > day {
            entry.lastDay = day
            entries[fingerprint] = entry
        }
        model = PersonalLexiconModel(options: model.options, entries: entries, generation: model.generation)
        return true
    }
}
