// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A word the user's undos taught Perekey to leave alone, in one app or everywhere.
public struct LearnedWord: Hashable, Sendable, Identifiable {
    /// The word and the app it is learned for: one entry per pair.
    public var id: String { word + "\u{0}" + (app ?? "") }
    /// The normalized word (see `WordRules.normalize`).
    public var word: String
    /// When it was learned, in seconds since 1970. A plain number keeps the core free of `Foundation`.
    public var learnedAt: Double
    /// How many times a correction of it was undone, the first one included.
    public var undoCount: Int
    /// When the last undo was, in seconds since 1970.
    public var lastUndoneAt: Double
    /// The bundle ID of the app it is left alone in; nil for everywhere.
    public var app: String?

    public init(word: String, learnedAt: Double, undoCount: Int = 1, lastUndoneAt: Double? = nil, app: String? = nil) {
        self.word = word
        self.learnedAt = learnedAt
        self.undoCount = undoCount
        self.lastUndoneAt = lastUndoneAt ?? learnedAt
        self.app = app
    }
}

extension LearnedWord: Codable {
    private enum CodingKeys: String, CodingKey {
        case word, learnedAt, undoCount, lastUndoneAt, app
    }

    /// Settings from before the undo count have only `word` and `learnedAt`:
    /// that is one undo, at the time it was learned. Settings from before
    /// the scopes have no `app`: everywhere. Older versions ignore `app`
    /// and read the word as learned everywhere.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let word = try container.decode(String.self, forKey: .word)
        let learnedAt = try container.decode(Double.self, forKey: .learnedAt)
        let count = (try? container.decodeIfPresent(Int.self, forKey: .undoCount)) ?? 1
        let last = (try? container.decodeIfPresent(Double.self, forKey: .lastUndoneAt)) ?? learnedAt
        let app = (try? container.decodeIfPresent(String.self, forKey: .app)) ?? nil
        self.init(word: word, learnedAt: learnedAt, undoCount: max(1, count), lastUndoneAt: last, app: app)
    }
}

/// A word whose corrections the user undid, not yet learned: its evidence
/// so far (`WordRules.count`). Never touched by the classifier's checks.
public struct LearningCandidate: Hashable, Sendable, Codable {
    public var word: String
    /// The bundle ID of the app the undos were in; nil for a word learned
    /// everywhere after one undo by an older version, counted in every app.
    public var app: String?
    /// The evidence so far (`LearningOptions`).
    public var evidence: Int
    /// The evidence it takes to ask, from the latest counted undo.
    public var threshold: Int
    /// The undos counted, those that gave no evidence left out.
    public var undoCount: Int
    /// When the first counted undo was, in seconds since 1970.
    public var firstUndoneAt: Double
    /// When the latest counted undo was: the candidate goes 30 days after it
    /// (`LearningOptions.candidateLifetime`).
    public var lastCountedAt: Double
    /// The calendar day of the latest counted undo, as the app numbers days.
    public var lastCountedDay: Int

    public init(word: String, app: String?, evidence: Int, threshold: Int, undoCount: Int, firstUndoneAt: Double,
                lastCountedAt: Double? = nil, lastCountedDay: Int)
    {
        self.word = word
        self.app = app
        self.evidence = evidence
        self.threshold = threshold
        self.undoCount = undoCount
        self.firstUndoneAt = firstUndoneAt
        self.lastCountedAt = lastCountedAt ?? firstUndoneAt
        self.lastCountedDay = lastCountedDay
    }

    /// Reached its threshold: the user was asked, or will be at the next counted undo.
    public var isRipe: Bool { evidence >= threshold }
}

/// The user's rules for single words, in three lists:
/// - "Не трогать: мои" (`mine`): typed in by the user, never corrected;
/// - "Не трогать: выученные" (`learned`): taught by undone corrections, never
///   corrected, in one app or everywhere; `candidates` hold the words on
///   their way there (`count`);
/// - "Всегда исправлять" (`always`): switched to at the end of the word whatever
///   the classifier's score, unless a guard keeps it (`Classifier.Reason.isGuard`).
///
/// Words are stored normalized: trimmed and lowercased. The autoswitch asks
/// about the word as typed in either layout reading, so a never-touch word
/// matches in whichever of the two readings the user put on the list, in any
/// letter case. An always-fix word is the form the word should come out in
/// ("артём", not "fhn`v"): typed in the other layout it switches to it, typed
/// in its own it stays. It matches with "ё" as "е" and "’" as "'"
/// (`matchKey`), and comes out spelt as stored.
///
/// Never-touch beats always-fix, in either reading of the word: adding to
/// "Мои" takes the word off "Всегда исправлять", `alwaysFix` refuses a word
/// of "Мои", and `AppSettings.snapshot` drops from the always list whatever
/// is on a never-touch one (an import may bring both). The other readings
/// come from the installed layouts (`readings(of:in:)`); the core has none of
/// its own, so the callers pass them.
public struct WordRules: Hashable, Sendable {
    public var mine: [String]
    /// At most one entry per word and app; a word learned everywhere has no
    /// entry for an app.
    public var learned: [LearnedWord]
    public var always: [String]
    /// Words undone but not learned yet, at most one per word and app.
    public var candidates: [LearningCandidate]
    /// Whether undone corrections count towards learning their words.
    public var learnFromUndos: Bool

    /// One of the three lists.
    public enum Section: Hashable, Sendable {
        case mine, learned, always
    }

    /// "Всегда исправлять" takes words of this many letters and more: a
    /// shorter one is too often meant as typed.
    public static let alwaysFixMinLetters = 3

    public init(mine: [String] = [], learned: [LearnedWord] = [], always: [String] = [],
                candidates: [LearningCandidate] = [], learnFromUndos: Bool = true)
    {
        self.mine = mine
        self.learned = learned
        self.always = always
        self.candidates = candidates
        self.learnFromUndos = learnFromUndos
    }

    public var isEmpty: Bool { mine.isEmpty && learned.isEmpty && always.isEmpty }
    public var count: Int { mine.count + learned.count + always.count }

    /// The stored form of a word: trimmed, lowercased.
    /// The Ukrainian apostrophe `ʼ` (U+02BC, what Ukrainian-PC types) is
    /// `'`, as the model reads it (`ModelFormat.fold`): «м'ясо» on a list
    /// matches «мʼясо» typed.
    public static func normalize(_ word: String) -> String {
        var text = Substring(word)
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        let lowered = text.lowercased()
        guard lowered.contains("\u{2BC}") else { return lowered }
        return String(lowered.map { $0 == "\u{2BC}" ? "'" : $0 })
    }

    /// The form "Всегда исправлять" matches by: normalized (so `ʼ` as "'"),
    /// "ё" as "е", "’" as "'".
    public static func matchKey(_ word: String) -> String {
        String(normalize(word).map { character -> Character in
            switch character {
            case "ё": "е"
            case "\u{2019}": "'"
            default: character
            }
        })
    }

    /// The always-fix words by `matchKey`, each with its stored spelling.
    public var alwaysFixTable: [String: String] {
        var table: [String: String] = [:]
        for word in always { table[Self.matchKey(word)] = word }
        return table
    }

    /// The word typed on the same keys in the other installed layouts,
    /// normalized: "аня" gives "fyz" with ABC and Russian.
    public static func readings(of word: String, in layouts: [LayoutMap]) -> [String] {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return [] }
        var readings: [String] = []
        for source in layouts where normalized.allSatisfy({ source.stroke(for: $0) != nil }) {
            for target in layouts where target.id != source.id && target.language != source.language {
                let reading = normalize(target.convert(normalized, from: source))
                if reading != normalized, !readings.contains(reading) { readings.append(reading) }
            }
        }
        return readings
    }

    /// Why a word can or cannot be added.
    public enum Validation: Hashable, Sendable {
        case ok
        case empty
        /// Not one word: it has characters other than letters, `'`, `’` and `-`.
        case invalid
        case duplicate
        /// Allowed, but the word is common: it will stop being corrected everywhere.
        case frequent
        /// Not for "Всегда исправлять": the word, in some reading, is on
        /// "Не трогать: мои", which wins.
        case neverTouch
        /// Not for "Всегда исправлять": fewer than `alwaysFixMinLetters` letters.
        case tooShort
    }

    /// Checks a word before adding it to `section`. `readings` are the word
    /// typed on the same keys in the other layouts (`readings(of:in:)`).
    /// `isFrequent` receives the normalized word and says whether it is among
    /// the 1000 most frequent; only a never-touch list warns about that.
    ///
    /// For "Мои" a word on a never-touch list, in any reading, is a
    /// duplicate; an always-fix one is fine, `add` moves it: never-touch wins.
    /// For "Всегда исправлять" a learned word is fine, `alwaysFix` forgets it;
    /// a word of "Мои" is not.
    public func validate(_ word: String, for section: Section = .mine, readings: [String] = [],
                         isFrequent: (String) -> Bool = { _ in false }) -> Validation
    {
        let normalized = Self.normalize(word)
        if normalized.isEmpty { return .empty }
        guard normalized.contains(where: \.isLetter),
              normalized.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        else { return .invalid }
        let forms = [normalized] + readings.map(Self.normalize)
        switch section {
        case .mine, .learned:
            if forms.contains(where: contains) { return .duplicate }
            return isFrequent(normalized) ? .frequent : .ok
        case .always:
            if normalized.filter(\.isLetter).count < Self.alwaysFixMinLetters { return .tooShort }
            if forms.contains(where: { self.section(of: $0) == .always }) { return .duplicate }
            if forms.contains(where: mine.contains) { return .neverTouch }
            return .ok
        }
    }

    /// The list a word is on, if any. Never-touch lists come first.
    public func section(of word: String) -> Section? {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty else { return nil }
        if mine.contains(normalized) { return .mine }
        if learned.contains(where: { $0.word == normalized }) { return .learned }
        let key = Self.matchKey(normalized)
        if always.contains(where: { Self.matchKey($0) == key }) { return .always }
        return nil
    }

    /// True when the word, as typed in one layout reading, is on a never-touch list.
    public func contains(_ reading: String) -> Bool {
        switch section(of: reading) {
        case .mine, .learned: true
        case .always, nil: false
        }
    }

    /// Adds a word to "Мои". A frequent word is allowed: the caller shows the
    /// warning first. A learned or always-fix copy, in any of `readings`,
    /// gives way to it. Returns false for an invalid word or one already
    /// there in some reading.
    @discardableResult
    public mutating func add(_ word: String, readings: [String] = []) -> Bool {
        let normalized = Self.normalize(word)
        let forms = [normalized] + readings.map(Self.normalize)
        guard validate(normalized) != .empty, validate(normalized) != .invalid,
              !forms.contains(where: mine.contains)
        else { return false }
        learned.removeAll { forms.contains($0.word) }
        candidates.removeAll { forms.contains($0.word) }
        let keys = Set(forms.map(Self.matchKey))
        always.removeAll { keys.contains(Self.matchKey($0)) }
        mine.append(normalized)
        return true
    }

    /// Removes a word from "Мои".
    public mutating func remove(_ word: String) {
        let normalized = Self.normalize(word)
        mine.removeAll { $0 == normalized }
    }

    /// Adds a word to "Всегда исправлять", in the form it should come out in.
    /// `readings` are its other readings (`readings(of:in:)`); `typed` is the
    /// one the user typed, when known (the hint after a manual retype passes
    /// it). The user says now that those are wrong, so a learned copy of any
    /// of them is forgotten. Returns false when `validate(_:for: .always)`
    /// refuses the word or `typed` is on "Мои".
    @discardableResult
    public mutating func alwaysFix(_ word: String, typed: String? = nil, readings: [String] = []) -> Bool {
        let normalized = Self.normalize(word)
        let others = (typed.map { [$0] } ?? []) + readings
        guard validate(normalized, for: .always, readings: others) == .ok else { return false }
        let forms = [normalized] + others.map(Self.normalize)
        learned.removeAll { forms.contains($0.word) }
        candidates.removeAll { forms.contains($0.word) }
        always.append(normalized)
        return true
    }

    /// Removes a word from "Всегда исправлять", whatever its "ё" and apostrophe.
    public mutating func stopFixing(_ word: String) {
        let key = Self.matchKey(word)
        always.removeAll { Self.matchKey($0) == key }
    }

    // MARK: - Learning from undos

    /// Counts an undone correction towards learning its word
    /// (docs/classifier.md, «Обучение»). Nothing is learned here: at the
    /// threshold the step asks (`LearningStep.question`), and the user's
    /// answer goes to `answer`.
    ///
    /// Does nothing when learning is off, or the word is invalid or on
    /// "Мои" in some reading. When the word or one of its `readings` is on
    /// "Всегда исправлять", the undo withdraws that instead and counts
    /// nothing: the latest explicit signal wins. A word learned for the app
    /// or everywhere counts one more undo. `day` is the calendar day of
    /// `seconds` as the app numbers days: an undo on another day than the
    /// last counted one adds `LearningOptions.newDayBonus`. Candidates with
    /// no counted undo for `candidateLifetime` go first.
    @discardableResult
    public mutating func count(_ report: UndoReport, at seconds: Double, day: Int, readings: [String] = [],
                               options: LearningOptions = LearningOptions()) -> LearningStep
    {
        let normalized = Self.normalize(report.word)
        let forms = [normalized] + readings.map(Self.normalize)
        let withdraws = forms.contains(where: { section(of: $0) == .always })
        let oldRule: LearningStep.OldRule = if !learnFromUndos {
            .nothing
        } else if withdraws {
            .withdraw
        } else if learned.contains(where: { $0.word == normalized }) {
            .count
        } else {
            validate(normalized, readings: readings) == .ok ? .learn : .nothing
        }
        guard learnFromUndos else { return LearningStep(outcome: .off, oldRule: oldRule) }
        if withdraws {
            for form in forms { stopFixing(form) }
            return LearningStep(outcome: .withdrawn, oldRule: oldRule)
        }
        if let index = learned.firstIndex(where: { $0.word == normalized && $0.covers(report.app) }) {
            learned[index].undoCount += 1
            learned[index].lastUndoneAt = seconds
            return LearningStep(outcome: .alreadyLearned, oldRule: oldRule)
        }
        // An undo whose app is unknown is no evidence for any scope.
        guard let app = report.app else {
            return LearningStep(outcome: .noEvidence, threshold: report.threshold, oldRule: oldRule)
        }
        guard isLearnable(normalized, readings: readings, app: app) else {
            return LearningStep(outcome: .notLearnable, oldRule: oldRule)
        }
        expireCandidates(at: seconds, options: options)

        let index = candidates.firstIndex { $0.word == normalized && $0.app == app }
            ?? candidates.firstIndex { $0.word == normalized && $0.app == nil }
        let weight = options.weight(report.channel, report.followUp)
        guard weight > 0 else {
            let candidate = index.map { candidates[$0] }
            return LearningStep(outcome: .noEvidence, evidence: candidate?.evidence ?? 0,
                                threshold: candidate?.threshold ?? report.threshold, oldRule: oldRule)
        }
        var candidate = index.map { candidates[$0] }
            ?? LearningCandidate(word: normalized, app: app, evidence: 0, threshold: report.threshold,
                                 undoCount: 0, firstUndoneAt: seconds, lastCountedDay: day)
        // A migrated candidate is seed evidence: it moves to the app of the first counted undo.
        candidate.app = app
        let newDay = candidate.undoCount > 0 && candidate.lastCountedDay != day
        candidate.evidence += weight + (newDay ? options.newDayBonus : 0)
        candidate.threshold = report.threshold
        candidate.undoCount += 1
        candidate.lastCountedAt = seconds
        candidate.lastCountedDay = day
        if let index { candidates[index] = candidate } else { candidates.append(candidate) }
        guard candidate.isRipe else {
            return LearningStep(outcome: .counted, evidence: candidate.evidence, threshold: candidate.threshold,
                                oldRule: oldRule)
        }
        let question = LearningQuestion(word: normalized, app: app,
                                        reachedElsewhere: !otherApps(normalized, than: app).isEmpty)
        return LearningStep(outcome: .ask, evidence: candidate.evidence, threshold: candidate.threshold,
                            oldRule: oldRule, question: question)
    }

    /// The user's answer to a `LearningQuestion`. "Только здесь" learns the
    /// word for its app, or everywhere when it is learned or ripe in another
    /// app too (`LearningOptions.appsForEverywhere`) or the app is unknown;
    /// "Везде" learns it everywhere; "Нет" starts its evidence over. Returns
    /// the entry learned, if any. Does nothing for a word put on another
    /// list in the meantime, for a candidate that `unlearn` or `forget` took
    /// away since the question, and for a word learned everywhere already.
    @discardableResult
    public mutating func answer(_ question: LearningQuestion, _ answer: LearningAnswer, at seconds: Double,
                                readings: [String] = [], options: LearningOptions = LearningOptions()) -> LearnedWord?
    {
        let word = Self.normalize(question.word)
        let asked = candidates.indices.filter { candidates[$0].word == word && candidates[$0].covers(question.app) }
        // A stale answer: the candidate is gone or no longer ripe, or the word is learned everywhere already.
        guard asked.contains(where: { candidates[$0].isRipe }),
              !learned.contains(where: { $0.word == word && $0.app == nil })
        else { return nil }
        if answer == .no {
            for index in asked { candidates[index].evidence = 0 }
            return nil
        }
        guard isLearnable(word, readings: readings, app: question.app) else { return nil }
        let undos = asked.reduce(0) { $0 + candidates[$1].undoCount }
        let firstUndo = asked.map { candidates[$0].firstUndoneAt }.min() ?? seconds
        let everywhere = answer == .everywhere || question.app == nil
            || otherApps(word, than: question.app).count + 1 >= options.appsForEverywhere
        let entry: LearnedWord
        if everywhere {
            let elsewhere = learned.filter { $0.word == word }.reduce(0) { $0 + $1.undoCount }
                + candidates.filter { $0.word == word && !$0.covers(question.app) }.reduce(0) { $0 + $1.undoCount }
            learned.removeAll { $0.word == word }
            candidates.removeAll { $0.word == word }
            entry = LearnedWord(word: word, learnedAt: firstUndo, undoCount: max(1, undos + elsewhere),
                                lastUndoneAt: seconds)
        } else {
            candidates.removeAll { $0.word == word && $0.covers(question.app) }
            // Asked twice and answered twice: one entry still.
            let before = learned.filter { $0.word == word && $0.app == question.app }
            learned.removeAll { $0.word == word && $0.app == question.app }
            entry = LearnedWord(word: word, learnedAt: before.map(\.learnedAt).min() ?? firstUndo,
                                undoCount: max(1, undos + before.reduce(0) { $0 + $1.undoCount }),
                                lastUndoneAt: seconds, app: question.app)
        }
        learned.append(entry)
        return entry
    }

    /// The user retyped a word by hand into the other layout: a learned copy
    /// of it, for `app` or everywhere, is wrong. Forgets it, and the
    /// evidence of its candidates there. `typed` is the word as it stood,
    /// `retyped` what the retype made of it. The learned copy is the one an
    /// undo of the same switch would have learned (`CorrectionUndo.learnable`):
    /// the typed reading, or the other one when the typed one is no word for
    /// the lists ("ds,jh" is learned as "выбор"). So retyping "привет" into
    /// "ghbdtn" keeps a learned "ghbdtn". Returns what was forgotten.
    @discardableResult
    public mutating func unlearn(typed: String, retyped: String, app: String?) -> Unlearned? {
        var keys: Set<String> = [Self.normalize(typed), WordJudge.exceptionKey(typed)]
        if let learnable = CorrectionUndo.learnable(typed, or: retyped) { keys.insert(learnable) }
        keys.remove("")
        candidates.removeAll { keys.contains($0.word) && $0.covers(app) }
        guard let index = learned.firstIndex(where: { keys.contains($0.word) && $0.covers(app) }) else { return nil }
        let entry = learned.remove(at: index)
        return Unlearned(word: entry.word, app: entry.app)
    }

    /// Drops the candidates without a counted undo for `candidateLifetime`.
    public mutating func expireCandidates(at seconds: Double, options: LearningOptions = LearningOptions()) {
        candidates.removeAll { seconds - $0.lastCountedAt > options.candidateLifetime }
    }

    /// The other apps where the word is learned or ripe.
    private func otherApps(_ word: String, than app: String?) -> Set<String> {
        var apps = Set(learned.lazy.filter { $0.word == word }.compactMap(\.app))
        for candidate in candidates where candidate.word == word && candidate.isRipe {
            if let other = candidate.app { apps.insert(other) }
        }
        if let app { apps.remove(app) }
        return apps
    }

    /// A valid word, on "Мои" in no reading, and no other reading learned for `app`.
    private func isLearnable(_ word: String, readings: [String], app: String?) -> Bool {
        switch validate(word) {
        case .ok, .frequent, .duplicate: break
        default: return false
        }
        let forms = [word] + readings.map(Self.normalize)
        if forms.contains(where: mine.contains) { return false }
        let keys = Set(forms.map(Self.matchKey))
        if always.contains(where: { keys.contains(Self.matchKey($0)) }) { return false }
        return !learned.contains { $0.word != word && forms.contains($0.word) && $0.covers(app) }
    }

    /// Whether the word is learned where `app` is in focus: for it, or everywhere.
    public func isLearned(_ word: String, in app: String?) -> Bool {
        let normalized = Self.normalize(word)
        return learned.contains { $0.word == normalized && $0.covers(app) }
    }

    /// The never-touch words of one app, beyond `mine` and the words learned everywhere.
    public var learnedByApp: [String: Set<String>] {
        var byApp: [String: Set<String>] = [:]
        for entry in learned {
            guard let app = entry.app else { continue }
            byApp[app, default: []].insert(entry.word)
        }
        return byApp
    }

    /// Forgets a learned word, in every app, and its candidates. "Мои" words stay; use `remove` for those.
    public mutating func forget(_ word: String) {
        let normalized = Self.normalize(word)
        learned.removeAll { $0.word == normalized }
        candidates.removeAll { $0.word == normalized }
    }

    /// Forgets a learned word in one app only; nil is the entry learned everywhere.
    public mutating func forget(_ word: String, app: String?) {
        let normalized = Self.normalize(word)
        learned.removeAll { $0.word == normalized && $0.app == app }
    }

    public mutating func forgetAllLearned() {
        learned.removeAll()
        candidates.removeAll()
    }

    // MARK: - Offering "Всегда исправлять"

    /// What `offerAlwaysFix` needs besides the classifier's decision.
    public struct OfferContext: Hashable, Sendable {
        /// Automatic switching was on when the word was typed.
        public var autoswitch: Bool
        /// The mode of the app the word was typed in.
        public var appMode: AppMode
        /// The word, in either reading, is on one of the lists already.
        public var listed: Bool

        public init(autoswitch: Bool, appMode: AppMode, listed: Bool = false) {
            self.autoswitch = autoswitch
            self.appMode = appMode
            self.listed = listed
        }
    }

    /// Whether the hint after a manual retype offers "Исправлять всегда"
    /// (docs/PLAN.md, stage 7, «Когда предлагать»): only when automatic
    /// switching could act on the word and left it out of doubt, not because
    /// of a guard. A word on a list was decided by the user already.
    /// A 1–2 letter word (`shortWord`) is a doubt but is not offered: the
    /// list does not take it (`alwaysFixMinLetters`).
    public static func offerAlwaysFix(decision: Classifier.Decision, context: OfferContext) -> Bool {
        context.autoswitch && context.appMode == .auto && !context.listed && decision.reason != .shortWord
            && overrides(decision)
    }

    /// Whether an always-fix word switches over this decision: the
    /// classifier kept the word or was unsure, and not because of a guard.
    /// A score of `-infinity` means the other reading is no word: nothing to switch to.
    public static func overrides(_ decision: Classifier.Decision) -> Bool {
        if case .switch = decision.verdict { return false }
        return !decision.reason.isGuard && decision.score > -.infinity
    }
}

extension Classifier.Reason {
    /// A reason no list overrides: it is about the shape of the token, not
    /// about how likely each reading is (docs/PLAN.md, stage 7, «Когда предлагать»).
    ///
    /// Guards: digits, password-like, code-like, mixed case (a capital inside
    /// the word: captchas, identifiers, product names), the model's
    /// never-switch list (`kept`), and the cases where there is no pair to
    /// compare (`empty`, `unsupported`, `tooLong`).
    ///
    /// Not guards: `noise`, `bothPlausible`, `shortWord` and `compared` below
    /// the threshold. They say how probable the readings are, and a word the
    /// user listed outweighs that. `noise` is a cost per letter above a bound,
    /// a score like the others; a random captcha is caught by the guards or
    /// never matches a listed word.
    public var isGuard: Bool {
        switch self {
        case .empty, .unsupported, .tooLong, .digits, .kept, .passwordLike, .codeLike, .mixedCase: true
        case .noise, .bothPlausible, .shortWord, .compared: false
        }
    }
}

extension LearnedWord {
    /// Applies where `app` is in focus: learned for it, or everywhere.
    func covers(_ app: String?) -> Bool {
        self.app == nil || self.app == app
    }
}

extension LearningCandidate {
    /// Counts for `app`: its own, or one counted in every app.
    func covers(_ app: String?) -> Bool {
        self.app == nil || self.app == app
    }
}

extension WordRules: Codable {
    private enum CodingKeys: String, CodingKey {
        case mine, learned, always, candidates, learnFromUndos, learning
    }

    /// The way of learning the file was written with, in `learning`:
    /// 2 learns by evidence (`count`). Files without it learned from one
    /// undo; `init(from:)` migrates them.
    static let learningVersion = 2

    /// `JSONDecoder.userInfo` key: a `Bool`, whether a file without `learning`
    /// migrates. The caller knows when the migration already ran on this Mac
    /// (`SettingsFile`): an older build drops `learning` on its save, and
    /// the next launch must not turn words learned by evidence into
    /// candidates. Without the key a file migrates.
    public static let migratesLearningKey = CodingUserInfoKey(rawValue: "perekey.migratesLearning")!

    /// Tolerant: missing keys take defaults, and one bad entry is skipped, not
    /// fatal. Settings from before "Всегда исправлять" have no `always`. A word
    /// on two lists stays on the first of `mine`, `learned`, `always`; a word
    /// learned twice for one app, or for an app and everywhere, stays once,
    /// everywhere winning.
    ///
    /// Settings from before learning by evidence (no `learning` key) learned
    /// a word from one undo: such a word becomes a candidate counted in
    /// every app, with the evidence of one Backspace; a word undone twice or
    /// more stays learned everywhere. Older versions read this file: they
    /// ignore `candidates`, `learning` and `app`, and take a word learned
    /// for an app as learned everywhere. A migrated candidate counts from the
    /// moment of the migration, so it does not expire at once.
    /// `migratesLearningKey` turns the migration off.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<String>()
        func words(_ key: CodingKeys) -> [String] {
            guard let raw = try? container.decodeIfPresent([String].self, forKey: key) else { return [] }
            var words: [String] = []
            for word in raw.map(Self.normalize) where !word.isEmpty && seen.insert(word).inserted {
                words.append(word)
            }
            return words
        }
        func list<Item: Decodable>(_ key: CodingKeys, of _: Item.Type) -> [Item] {
            guard var list = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
            var items: [Item] = []
            while !list.isAtEnd {
                guard let item = try? list.decode(Item.self) else {
                    _ = try? list.decode(Skip.self)
                    continue
                }
                items.append(item)
            }
            return items
        }
        let mine = words(.mine)
        let migrates = decoder.userInfo[Self.migratesLearningKey] as? Bool ?? true
        let version = (try? container.decodeIfPresent(Int.self, forKey: .learning)) ?? (migrates ? 1 : Self.learningVersion)
        let migratedAt = Date().timeIntervalSince1970
        var learned: [LearnedWord] = []
        var candidates: [LearningCandidate] = []
        let stored = list(.learned, of: LearnedWord.self)
        let everywhere = Set(stored.filter { $0.app == nil }.map { Self.normalize($0.word) })
        var scoped = Set<[String]>()
        let migration = LearningOptions()
        for var item in stored {
            item.word = Self.normalize(item.word)
            guard !item.word.isEmpty, !mine.contains(item.word),
                  scoped.insert([item.word, item.app ?? ""]).inserted,
                  item.app == nil || !everywhere.contains(item.word)
            else { continue }
            if version < Self.learningVersion, item.undoCount <= 1 {
                // Days since 1970 in UTC: near enough to the app's local days for one bonus.
                let day = Int((item.lastUndoneAt / 86_400).rounded(.down))
                candidates.append(LearningCandidate(
                    word: item.word, app: nil, evidence: migration.backspaceWeight,
                    threshold: migration.ordinaryThreshold, undoCount: 1, firstUndoneAt: item.learnedAt,
                    lastCountedAt: migratedAt, lastCountedDay: day
                ))
            } else {
                learned.append(item)
            }
        }
        // A word migrated to a candidate was never-touch: it keeps its place over "Всегда исправлять".
        seen.formUnion(learned.map(\.word) + candidates.map(\.word))
        var counted = Set<[String]>()
        for var item in list(.candidates, of: LearningCandidate.self) {
            item.word = Self.normalize(item.word)
            // A word may be learned for one app and counted in another.
            guard !item.word.isEmpty, !mine.contains(item.word),
                  !learned.contains(where: { $0.word == item.word && $0.covers(item.app) }),
                  counted.insert([item.word, item.app ?? ""]).inserted
            else { continue }
            candidates.append(item)
        }
        let always = words(.always)
        let fixed = Set(always.map(Self.matchKey))
        self.mine = mine
        self.learned = learned
        self.always = always
        self.candidates = candidates.filter { !fixed.contains(Self.matchKey($0.word)) }
        learnFromUndos = (try? container.decodeIfPresent(Bool.self, forKey: .learnFromUndos)) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mine, forKey: .mine)
        try container.encode(learned, forKey: .learned)
        try container.encode(always, forKey: .always)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(learnFromUndos, forKey: .learnFromUndos)
        try container.encode(Self.learningVersion, forKey: .learning)
    }
}

/// Steps past one array element that failed to decode.
private struct Skip: Decodable {
    init(from decoder: any Decoder) throws {}
}
