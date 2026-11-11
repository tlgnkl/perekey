// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
import PerekeyModelKit

/// What a simulated run of days found (docs/eval.md, «Обучение»).
public struct LearningRun: Hashable, Sendable, Codable {
    public struct Day: Hashable, Sendable, Codable {
        public var day: Int
        public var messages = 0
        /// Tokens the person meant as typed, and tokens they meant the other reading.
        public var keep = 0
        public var other = 0
        /// Keep tokens Perekey corrected before the person answered.
        public var harmed = 0
        public var undoneByBackspace = 0
        public var undoneByButton = 0
        /// `convertLastWord` by hand.
        public var converted = 0
        /// Backspaces for the space that undid a right correction.
        public var accidents = 0
        /// Tokens left wrong in the text at the end of the message.
        public var leftWrong = 0
        /// Undos that gave evidence, and questions asked.
        public var counted = 0
        public var asked = 0
        public var learned = 0
        public var unlearned = 0

        /// What the person had to do by hand: undos and retypes.
        public var interventions: Int { undoneByBackspace + undoneByButton + converted }
    }

    public struct Word: Hashable, Sendable, Codable {
        public var word: String
        public var layout: String
        public var keep = 0
        public var other = 0
        /// Keep tokens Perekey corrected.
        public var harmed = 0
        /// Undos of keep tokens.
        public var keepInterventions = 0
        /// Retypes by hand of other tokens Perekey left (the word was learned).
        public var otherInterventions = 0
        /// The first day the word was learned, if it was.
        public var learnedDay: Int?
        /// Evidence points the word got from accidental Backspaces (a Backspace for the space that the
        /// person followed by typing on), the day bonus of such an undo included.
        public var accidentPoints = 0
        /// The word was learned for the first time on points of accidental Backspaces: without them its
        /// evidence was below the threshold at the question. This is a false learning (docs/eval.md).
        public var learnedByAccident = false
        public var unlearned = 0
        /// Other tokens that needed a retype by hand because the word was learned.
        public var neededAfterLearned = 0
        /// The last keep token needed no undo.
        public var silent: Bool?
    }

    public struct Totals: Hashable, Sendable, Codable {
        public var tokens = 0
        public var keep = 0
        public var other = 0
        public var harmed = 0
        public var interventions = 0
        public var undoneByBackspace = 0
        public var undoneByButton = 0
        public var converted = 0
        public var accidents = 0
        public var leftWrong = 0
        public var counted = 0
        public var asked = 0
        /// Words learned (an entry on «Не трогать: выученные» at some time).
        public var learnedWords = 0
        /// Words learned on points of accidental Backspaces (`Word.learnedByAccident`): learned wrongly.
        public var falseLearned = 0
        /// `falseLearned` per 1000 accidental Backspaces.
        public var falseLearnedPer1000Accidents: Double?
        /// Learned words that later needed a retype by hand.
        public var learnedThenNeeded = 0
        public var unlearned = 0
        /// Words in whose first counted undo the rule before the evidence would have learned them.
        public var oldRuleWouldLearn = 0
        /// Words with a keep token Perekey corrected.
        public var wordsHarmed = 0
        /// Of them, words whose last keep token needed no undo.
        public var wordsSilent = 0
        /// Words harmed whose last keep token still needed an undo: they never went silent.
        public var wordsNeverSilent: Int { wordsHarmed - wordsSilent }
        /// Undos of keep tokens per word, mean over the words that went silent only: the words that
        /// never went silent (`wordsNeverSilent`) are not in it.
        public var interventionsToSilence: Double?
        public var interventionsDay1 = 0
        public var interventionsLastDay = 0
    }

    public var days: [Day]
    public var words: [Word]
    public var totals: Totals
}

/// The days of a person with a personal vocabulary, typed on `InputMachine`
/// with the learning loop of the app around it (docs/eval.md, «Обучение»):
/// `Effect.undoSettled` → `WordRules.count` → the answer to the question by
/// the policy of the manifest → `settingsChanged`; a retype by hand →
/// `WordRules.unlearn`. The core is not changed: `LearningOptions` are given
/// to `WordRules` here.
public struct LearningSimulation {
    public struct Config: Sendable {
        public var manifest: LearningManifest
        public var vocabulary: LearningVocabulary
        public var library: LayoutLibrary
        public var classifier: Classifier?
        public var options = LearningOptions()
        public var seed: UInt64

        public init(manifest: LearningManifest, vocabulary: LearningVocabulary, library: LayoutLibrary,
                    classifier: Classifier?, options: LearningOptions = LearningOptions(), seed: UInt64? = nil)
        {
            self.manifest = manifest
            self.vocabulary = vocabulary
            self.library = library
            self.classifier = classifier
            self.options = options
            self.seed = seed ?? manifest.seed
        }
    }

    private struct Resolved {
        var word: String
        var layoutName: String
        var layout: LayoutID
        /// The same keys in the other layout.
        var other: String
        var otherName: String
    }

    private enum Intent { case keep, other }

    /// Seconds between two messages: the person does something else between them.
    private static let messageGap = 600.0
    /// Seconds a person takes to press a key after seeing the text.
    private static let beat = 0.2

    private let config: Config
    private let typist = Typist()
    private let baseSettings: Settings
    private let resolved: [Resolved]
    private let names: [LayoutID: String]
    private let weights: [Double]
    private var desk: EvalDesk
    private var rules = WordRules()
    private var random: SplitMix64
    private var reactor: Typist.Reactor
    private var clock = 0.0
    private var cursor = 0
    private var postedCursor = 0
    private var drift: String?
    private var days: [LearningRun.Day] = []
    private var words: [LearningRun.Word]
    private var keepHistory: [[Bool]]
    private var oldRuleLearn: Set<Int> = []
    /// The word of an accidental Backspace that waits for the follow-up that settles it.
    private var accidentOpen: Int?
    /// By word and app: the evidence at the last counted undo, and the part of it that accidents gave.
    private var lastEvidence: [String: Int] = [:]
    private var accidentShare: [String: Int] = [:]
    private var indexOf: [String: Int] = [:]

    public static func run(_ config: Config) throws -> LearningRun {
        var simulation = try LearningSimulation(config)
        return try simulation.run()
    }

    init(_ config: Config) throws {
        self.config = config
        let manifest = config.manifest
        let maps = try manifest.layouts.map { name -> LayoutMap in
            guard let map = config.library[name] else { throw EvalError.input("\(manifest.name): unknown layout \(name)") }
            return map
        }
        names = Dictionary(uniqueKeysWithValues: zip(maps.map(\.id), manifest.layouts))
        var resolved: [Resolved] = []
        for entry in config.vocabulary.entries {
            guard let index = manifest.layouts.firstIndex(of: entry.layout) else {
                throw EvalError.input("\(manifest.name): \(entry.word) is written in \(entry.layout), not one of the layouts")
            }
            let other = 1 - index
            guard WordRules.normalize(entry.word) == entry.word else {
                throw EvalError.input("\(manifest.name): \(entry.word) is not in the stored form (lowercase, trimmed)")
            }
            let readings = WordRules.readings(of: entry.word, in: maps)
            guard let reading = readings.first(where: { text in text.allSatisfy { LayoutLibrary.printableStroke($0, in: maps[other]) != nil } }),
                  entry.word.allSatisfy({ LayoutLibrary.printableStroke($0, in: maps[index]) != nil })
            else {
                throw EvalError.input("\(manifest.name): \(entry.word) has no reading to type in \(manifest.layouts[other])")
            }
            resolved.append(Resolved(word: entry.word, layoutName: entry.layout, layout: maps[index].id, other: reading,
                                     otherName: manifest.layouts[other]))
        }
        self.resolved = resolved
        weights = (0..<resolved.count).map { 1 / pow(Double($0 + 1), manifest.zipf) }
        words = resolved.map { LearningRun.Word(word: $0.word, layout: $0.layoutName) }
        keepHistory = Array(repeating: [], count: resolved.count)
        for (index, item) in resolved.enumerated() {
            indexOf[item.word] = index
            indexOf[WordRules.normalize(item.other)] = indexOf[WordRules.normalize(item.other)] ?? index
        }
        var base = try EvalSettings.settings(for: Env(settings: manifest.effectiveSettings))
        base.learnFromUndos = true
        baseSettings = base
        let apps = manifest.effectiveApps
        desk = EvalDesk(EvalDesk.Setup(settings: base, layouts: maps, start: maps[0].id, classifier: config.classifier,
                                       focus: Focus(bundleID: apps[0])))
        random = SplitMix64(seed: config.seed)
        reactor = Typist.Reactor(options: manifest.reactorOptions, seed: config.seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    // MARK: - The days

    mutating func run() throws -> LearningRun {
        let manifest = config.manifest
        let apps = manifest.effectiveApps
        for day in 0..<manifest.days {
            days.append(LearningRun.Day(day: day))
            clock = Double(day) * 86_400 + 9 * 3_600
            for _ in 0..<manifest.messagesPerDay {
                clock += Self.messageGap
                let app = apps.count == 1 ? apps[0] : apps[Int(random.next() % UInt64(apps.count))]
                desk.send(.focus(Focus(bundleID: app)), at: clock)
                days[day].messages += 1
                for _ in 0..<manifest.effectiveWordsPerMessage { try token(day: day, app: app) }
                try press([.key(.return, n: nil, mods: nil)])
                drain(day: day)
            }
        }
        desk.finish()
        drain(day: manifest.days - 1)
        if let drift { throw EvalError.input("\(manifest.name): \(drift); the stand's threshold no longer follows LearningOptions.threshold") }
        return summary()
    }

    /// A word of the vocabulary by Zipf's law.
    private mutating func pick() -> Int {
        let total = weights.reduce(0, +)
        var point = Double(random.next() >> 11) / Double(1 << 53) * total
        for (index, weight) in weights.enumerated() {
            point -= weight
            if point < 0 { return index }
        }
        return weights.count - 1
    }

    private mutating func token(day: Int, app: String) throws {
        let index = pick()
        let item = resolved[index]
        let intent: Intent = Double(random.next() >> 11) / Double(1 << 53) < config.manifest.meantOther ? .other : .keep
        let text = intent == .keep ? item.word : item.other
        let typedOn = intent == .keep ? item.layoutName : item.otherName
        if desk.appLayout != item.layout {
            clock += Self.beat
            desk.send(.userLayout(item.layout), at: clock)
        }
        let learnedBefore = isLearned(item, app: app)
        let corrections = desk.corrections.count
        try press([.type(text + " ", on: typedOn)])
        try look(day: day)
        let corrected = desk.corrections.count > corrections
        let seen = Typist.Reactor.Seen(asMeant: desk.text.hasSuffix(text + " "), corrected: corrected)
        var intervened = false
        switch reactor.react(seen) {
        case .nothing:
            break
        case .undoByBackspace:
            accidentOpen = nil
            try press([.key(.backspace, n: nil, mods: nil)])
            days[day].undoneByBackspace += 1
            intervened = true
        case .undoByButton:
            clock += Self.beat
            desk.send(.undoButton, at: clock)
            days[day].undoneByButton += 1
            intervened = true
        case .convert:
            try press([.hotkey(.convertLastWord)])
            days[day].converted += 1
            intervened = true
        case let .accidentalBackspace(end):
            if end == .continues { accidentOpen = index }
            try press([.key(.backspace, n: nil, mods: nil)])
            days[day].accidents += 1
            // The person sees the word come back as typed.
            try look(day: day)
            switch end {
            case .continues:
                break
            case .retype:
                try press([.hotkey(.convertLastWord)])
                days[day].converted += 1
                intervened = true
            case .punctuation:
                // The space goes, the comma comes; the word stays as it was typed.
                try press([.key(.backspace, n: nil, mods: nil)])
                try press([.type(",", on: names[desk.appLayout] ?? item.layoutName)])
            }
        }
        try look(day: day)
        if !trimmed(desk.text).hasSuffix(text) { days[day].leftWrong += 1 }
        switch intent {
        case .keep:
            days[day].keep += 1
            if !seen.asMeant { days[day].harmed += 1 }
            words[index].keep += 1
            if !seen.asMeant { words[index].harmed += 1 }
            if intervened { words[index].keepInterventions += 1 }
            keepHistory[index].append(intervened)
        case .other:
            days[day].other += 1
            words[index].other += 1
            if intervened { words[index].otherInterventions += 1 }
            if learnedBefore, !corrected {
                words[index].neededAfterLearned += 1
            }
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " ,\n"))
    }

    private func isLearned(_ item: Resolved, app: String) -> Bool {
        rules.isLearned(item.word, in: app) || rules.isLearned(WordRules.normalize(item.other), in: app)
    }

    // MARK: - Typing

    /// Types the steps from now on, then waits for the person to see the result.
    private mutating func press(_ steps: [Step]) throws {
        let events = try typist.events(of: steps, env: Env(settings: config.manifest.effectiveSettings),
                                       layouts: config.library, label: config.manifest.name, startingAt: clock + Self.beat,
                                       endPause: false)
        for event in events { desk.send(event.event, at: event.time) }
        clock = events.last?.time ?? clock
    }

    /// The person looks at the text: the machine catches up and the learning loop sees what it reported.
    private mutating func look(day: Int) throws {
        let reaction = config.manifest.reactorOptions.reaction
        clock += reaction
        desk.send(.idle(seconds: reaction), at: clock)
        drain(day: day)
    }

    // MARK: - The learning loop

    private mutating func drain(day: Int) {
        while cursor < desk.log.count {
            let effect = desk.log[cursor].effect
            cursor += 1
            switch effect {
            case let .undoSettled(report):
                count(report, day: day)
            default:
                break
            }
        }
        while postedCursor < desk.posted.count {
            let retype = desk.posted[postedCursor].retype
            postedCursor += 1
            // As `InputController`: a word retyped by hand with the shortcut is wrong to have learned.
            guard case .manual(.convertLastWord) = retype.origin,
                  let unlearned = rules.unlearn(typed: retype.expected, retyped: retype.text, app: retype.app)
            else { continue }
            days[day].unlearned += 1
            if let index = indexOf[unlearned.word] { words[index].unlearned += 1 }
            publish()
        }
    }

    private mutating func count(_ original: UndoReport, day: Int) {
        var report = original
        report.threshold = threshold(of: original)
        // At the defaults the threshold must be the machine's own; if it is not, the copy has drifted from the core.
        if config.options == LearningOptions(), report.threshold != original.threshold, drift == nil {
            drift = "the threshold of an undo is \(original.threshold) in the machine and \(report.threshold) here"
        }
        let readings = WordRules.readings(of: report.word, in: layoutMaps)
        let step = rules.count(report, at: desk.time, day: Int(desk.time / 86_400), readings: readings,
                               options: config.options)
        if step.oldRule == .learn, let index = indexOf[WordRules.normalize(report.word)] { oldRuleLearn.insert(index) }
        if step.outcome == .counted || step.outcome == .ask { days[day].counted += 1 }
        // The points of a Backspace that the person typed on after, with no purpose but the space, are the accidents'.
        let accidental = report.channel == .backspace && accidentOpen != nil
        if report.channel == .backspace { accidentOpen = nil }
        let key = WordRules.normalize(report.word) + "\u{0}" + (report.app ?? "")
        if step.outcome == .counted || step.outcome == .ask,
           let candidate = rules.candidates.first(where: { $0.word == WordRules.normalize(report.word) && $0.app == report.app })
        {
            // A first counted undo starts a candidate; later ones add the difference.
            let gained = candidate.undoCount == 1 ? candidate.evidence : candidate.evidence - (lastEvidence[key] ?? 0)
            if candidate.undoCount == 1 { accidentShare[key] = 0 }
            if accidental {
                accidentShare[key, default: 0] += gained
                if let index = indexOf[WordRules.normalize(report.word)] { words[index].accidentPoints += gained }
            }
            lastEvidence[key] = candidate.evidence
        }
        guard let question = step.question else { return }
        days[day].asked += 1
        let answer: LearningAnswer
        switch config.manifest.answer {
        case .everywhere: answer = .everywhere
        case .here: answer = .here
        case .never: return
        }
        guard let learned = rules.answer(question, answer, at: desk.time, readings: readings, options: config.options)
        else { return }
        days[day].learned += 1
        if let index = indexOf[learned.word], words[index].learnedDay == nil {
            words[index].learnedDay = day
            // Without the points of the accidents, was the evidence below the bar at the question?
            words[index].learnedByAccident = step.evidence - (accidentShare[key] ?? 0) < step.threshold
        }
        publish()
    }

    private var layoutMaps: [LayoutMap] { config.manifest.layouts.compactMap { config.library[$0] } }

    /// The threshold the swept options give the undo. The machine reports the
    /// one of the default `LearningOptions` (`CorrectionUndo`); at the defaults
    /// both are the same.
    private func threshold(of report: UndoReport) -> Int {
        let rank = config.classifier?.options.shortWordRank ?? Classifier.Options().shortWordRank
        guard let typed = report.facts.typedForm, let typedForm = Self.form(typed),
              let other = report.facts.otherForm, let otherForm = Self.form(other)
        else { return config.options.threshold(for: nil, frequentRank: rank) }
        var decision = Classifier.Decision(verdict: .keep, score: 0, reason: .compared, language: nil,
                                           typedForm: typedForm, otherForm: otherForm)
        decision.typedRank = report.facts.typedRank
        decision.otherRank = report.facts.otherRank
        return config.options.threshold(for: decision, frequentRank: rank)
    }

    private static func form(_ name: String) -> Classifier.Form? {
        switch name {
        case "notWord": .notWord
        case "unknown": .unknown
        case "rare": .rare
        case "known": .known
        default: nil
        }
    }

    /// The settings the app would send now: the preset with the words learned.
    private mutating func publish() {
        var app = AppSettings()
        app.words = rules
        let snapshot = app.snapshot
        var settings = baseSettings
        settings.exceptions = snapshot.exceptions
        settings.appExceptions = snapshot.appExceptions
        settings.alwaysFix = snapshot.alwaysFix
        desk.replay(.settingsChanged(settings))
    }

    // MARK: - The result

    private func summary() -> LearningRun {
        var words = self.words
        var totals = LearningRun.Totals()
        var toSilence = 0
        for index in words.indices {
            if let last = keepHistory[index].last, words[index].harmed > 0 { words[index].silent = !last }
            totals.wordsHarmed += words[index].harmed > 0 ? 1 : 0
            if words[index].harmed > 0, words[index].silent == true {
                totals.wordsSilent += 1
                toSilence += words[index].keepInterventions
            }
            if words[index].learnedDay != nil {
                totals.learnedWords += 1
                if words[index].learnedByAccident { totals.falseLearned += 1 }
                if words[index].neededAfterLearned > 0 { totals.learnedThenNeeded += 1 }
            }
        }
        for day in days {
            totals.keep += day.keep
            totals.other += day.other
            totals.harmed += day.harmed
            totals.interventions += day.interventions
            totals.undoneByBackspace += day.undoneByBackspace
            totals.undoneByButton += day.undoneByButton
            totals.converted += day.converted
            totals.accidents += day.accidents
            totals.leftWrong += day.leftWrong
            totals.counted += day.counted
            totals.asked += day.asked
            totals.unlearned += day.unlearned
        }
        totals.tokens = totals.keep + totals.other
        totals.oldRuleWouldLearn = oldRuleLearn.count
        if totals.accidents > 0 { totals.falseLearnedPer1000Accidents = Double(totals.falseLearned) * 1000 / Double(totals.accidents) }
        if totals.wordsSilent > 0 { totals.interventionsToSilence = Double(toSilence) / Double(totals.wordsSilent) }
        totals.interventionsDay1 = days.first?.interventions ?? 0
        totals.interventionsLastDay = days.last?.interventions ?? 0
        return LearningRun(days: days, words: words, totals: totals)
    }
}
