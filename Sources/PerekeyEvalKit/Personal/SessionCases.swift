// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyModelKit

/// Turns a recorded session (`.pksession`) into a personal set: the cases of
/// the words the person's own behaviour judged (docs/eval.md, «Личные
/// наборы»). What the person did after Perekey's decision is the label
/// (`SessionWords`, docs/classifier.md): a strong label makes a case, a weak
/// one does not. `want` is what that behaviour says the person meant.
///
/// | Label, strong            | The case                                                          |
/// |--------------------------|-------------------------------------------------------------------|
/// | false switch             | the word as typed, fingers and layout the same: harm if switched |
/// | wrong correction         | the same: harm if corrected                                       |
/// | miss                     | the keys in the layout the person retyped them in: fixed if switched |
/// | switch put back by hand  | the keys in the layout Perekey switched to: the same              |
///
/// The words right before it, in one focus and one go, are its warm-up: the
/// context the classifier saw.
public enum SessionCases {
    /// The tags a personal case may carry. No word of a recording gets into
    /// a tag, so the slices and the report stay free of words.
    public static let allowedTags: Set<String> = ["personal", "falseSwitch", "wrongCorrection", "miss", "switchKept", "warm"]

    public struct Options: Sendable {
        /// Words before the one judged that go into the warm-up. The
        /// classifier reads the languages of the last three words
        /// (`Classifier.Context`), so a fourth changes nothing.
        public var contextWords = 3
        /// The name after `personal.` in the suite: `personal.<name>`.
        public var name = "sessions"

        public init() {}
    }

    /// Why a word makes no case. Only the counts are printed.
    public enum Skip: String, CaseIterable, Sendable {
        /// The label is weak or none: the person said nothing about the word.
        case notStrong
        /// A miss retyped by erasing: the layout it went to is not known, and
        /// the session has more than two layouts.
        case noTarget
        /// The keys do not type in format v1: ⌥, Caps Lock, or a key that types nothing.
        case notPrintable
        /// A strong label a case cannot say (a word correction put back by hand).
        case unsupported
        /// A layout of the recording is not in `eval/layouts/`.
        case layoutNotInLibrary
        /// The word is the same in both layouts: the layout changes nothing.
        case sameInBothLayouts
        /// Null gets the word wrong in a case that should be right.
        case nullWrongInClean
        /// The word is after the first answer that differs from the recording.
        case afterMismatch
        /// The same case came before.
        case duplicate
    }

    public struct Report: Sendable {
        public var files = 0
        public var segments = 0
        /// Segments whose replay differs from the recording.
        public var mismatched = 0
        public var words = 0
        /// Words by label and strength: `falseSwitch.strong`, `right.weak`.
        public var labels: [String: Int] = [:]
        public var cases = 0
        public var byScenario: [String: Int] = [:]
        public var skipped: [Skip: Int] = [:]
        /// Cases with a warm-up, and the words of all warm-ups.
        public var warm = 0
        public var warmupWords = 0

        public mutating func add(_ other: Report) {
            files += other.files
            segments += other.segments
            mismatched += other.mismatched
            words += other.words
            cases += other.cases
            warm += other.warm
            warmupWords += other.warmupWords
            labels.merge(other.labels, uniquingKeysWith: +)
            byScenario.merge(other.byScenario, uniquingKeysWith: +)
            skipped.merge(other.skipped, uniquingKeysWith: +)
        }

        /// Counts only, never a word.
        public func render() -> String {
            var lines = ["\(files) files, \(segments) segments (\(mismatched) replay otherwise than recorded), \(words) words"]
            lines.append("labels: " + (labels.isEmpty ? "none" : labels.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
            let scenarios = byScenario.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append("cases: \(cases)" + (scenarios.isEmpty ? "" : " (\(scenarios))")
                + "; with a warm-up \(warm), warm-up words \(warmupWords)")
            let skips = Skip.allCases.compactMap { skip in skipped[skip].map { "\(skip.rawValue) \($0)" } }
            lines.append("not made: " + (skips.isEmpty ? "none" : skips.joined(separator: ", ")))
            return lines.joined(separator: "\n")
        }
    }

    /// The classifier for a recorded spec; nil for none.
    public typealias ClassifierSource = (ClassifierSpec) -> Classifier?

    /// A layout of the recording that the library has.
    struct Known {
        var name: String
        var id: LayoutID
    }

    /// The cases of a session, in the order of the recording, and the counts.
    /// `seen` holds the ids made before, so one case comes once from many files.
    public static func build(_ session: Session, library: LayoutLibrary, classifier: ClassifierSource,
                             options: Options = Options(), seen: inout Set<String>) throws
        -> (cases: [EvalCase], report: Report)
    {
        var report = Report()
        report.files = 1
        var cases: [EvalCase] = []
        let names = layoutNames(library)
        for (number, segment) in session.segments.enumerated() {
            report.segments += 1
            let run = SessionDriver.run(segment, mode: .exact, classifier: classifier)
            let words = SessionWords.extract(run)
            report.words += words.count
            // The labels hold while the replay answers as the recording did.
            let valid = run.mismatch.map { mismatch in words.prefix { $0.step < mismatch.step }.count } ?? words.count
            if run.mismatch != nil { report.mismatched += 1 }
            for word in words {
                report.labels["\(word.label.rawValue).\(word.strength?.rawValue ?? "none")", default: 0] += 1
            }
            let layouts = segment.snapshot.machine.layouts.compactMap { map in
                names[map.id].map { Known(name: $0, id: map.id) }
            }
            for index in words.indices {
                guard words[index].strength == .strong else {
                    report.skipped[.notStrong, default: 0] += 1
                    continue
                }
                guard index < valid else {
                    report.skipped[.afterMismatch, default: 0] += 1
                    continue
                }
                let made = try make(index, of: words, run: run, layouts: layouts, library: library, names: names,
                                    allLayouts: segment.snapshot.machine.layouts.count, options: options,
                                    ref: "s\(number + 1).e\(words[index].step)")
                switch made {
                case let .failure(failure):
                    report.skipped[failure.reason, default: 0] += 1
                case let .success(built):
                    guard seen.insert(built.item.id).inserted else {
                        report.skipped[.duplicate, default: 0] += 1
                        continue
                    }
                    cases.append(built.item)
                    report.cases += 1
                    report.byScenario[built.item.scenario, default: 0] += 1
                    if built.warmupWords > 0 {
                        report.warm += 1
                        report.warmupWords += built.warmupWords
                    }
                }
            }
        }
        return (cases, report)
    }

    /// The library's name of each layout id: the first by name when two share one.
    static func layoutNames(_ library: LayoutLibrary) -> [LayoutID: String] {
        var names: [LayoutID: String] = [:]
        for name in library.maps.keys.sorted() {
            if let map = library[name], names[map.id] == nil { names[map.id] = name }
        }
        return names
    }

    struct Failure: Error {
        var reason: Skip
    }

    struct Built {
        var item: EvalCase
        var warmupWords: Int
    }

    /// A word as the person ended up with it: the layout it was written in
    /// and its text there.
    struct Settled {
        var layout: LayoutID
        var text: String
    }

    private static func make(_ index: Int, of words: [ObservedWord], run: ReplayRun, layouts: [Known],
                             library: LayoutLibrary, names: [LayoutID: String], allLayouts: Int, options: Options,
                             ref: String) throws -> Result<Built, Failure>
    {
        let word = words[index]
        let trace = word.trace
        guard layouts.count >= 2, let active = trace.layout, let activeName = names[active] else {
            return .failure(Failure(reason: .layoutNotInLibrary))
        }
        // The layout the fingers aim at, the case's tag and its scenario.
        let aim: LayoutID
        let tag: String
        let scenario: String
        switch (word.label, trace.action) {
        case (.falseSwitch, _):
            (aim, tag, scenario) = (active, "falseSwitch", "clean")
        case (.wrongCorrection, _):
            (aim, tag, scenario) = (active, "wrongCorrection", "clean")
        case (.miss, _):
            if let target = word.retypedTo {
                (aim, tag, scenario) = (target, "miss", "slip")
            } else if allLayouts == 2, let other = layouts.first(where: { $0.id != active })?.id {
                (aim, tag, scenario) = (other, "miss", "slip")
            } else {
                return .failure(Failure(reason: .noTarget))
            }
        case let (.right, .switched(to, _)):
            (aim, tag, scenario) = (to, "switchKept", "slip")
        default:
            return .failure(Failure(reason: .unsupported))
        }
        guard let aimName = names[aim], let aimMap = library[aimName] else {
            return .failure(Failure(reason: .layoutNotInLibrary))
        }
        if scenario == "slip", aim == active { return .failure(Failure(reason: .sameInBothLayouts)) }
        guard let text = render(trace.keys, in: aimMap) else { return .failure(Failure(reason: .notPrintable)) }

        // The warm-up: the words right before, as the person saw them.
        var context: [Settled] = []
        var at = index
        while context.count < options.contextWords, at > 0 {
            guard !broken(run, between: words[at - 1].step, and: words[at].step),
                  let before = settled(words[at - 1], library: library, names: names)
            else { break }
            context.insert(before, at: 0)
            at -= 1
        }

        var warmup: [Step] = []
        var inForce = context.first?.layout ?? active
        for (position, before) in context.enumerated() {
            guard let name = names[before.layout] else { return .failure(Failure(reason: .layoutNotInLibrary)) }
            if position > 0, before.layout != inForce { warmup.append(.layout(name)) }
            if case let .type(text, on)? = warmup.last, on == name {
                warmup[warmup.count - 1] = .type(text + before.text + " ", on: name)
            } else {
                warmup.append(.type(before.text + " ", on: name))
            }
            inForce = before.layout
        }
        var script: [Step] = []
        if !context.isEmpty, inForce != active { script.append(.layout(activeName)) }
        script.append(.type(text + " ", on: aimName))
        let start = context.first.flatMap { names[$0.layout] } ?? activeName

        var env: Env?
        if let app = trace.app, app != Env.defaultApp { env = Env(app: app) }
        var item = EvalCase(
            suite: "personal.\(options.name)", scenario: scenario + (context.isEmpty ? ".cold" : ".warm"), split: .dev,
            layouts: layouts.map(\.name), start: start, env: env, warmup: warmup.isEmpty ? nil : warmup,
            script: script, want: context.map { $0.text + " " }.joined() + text,
            tokens: [TokenSpec(t: text, lang: aimMap.language ?? "-", err: .none)],
            tags: ["personal", tag] + (context.isEmpty ? [] : ["warm"]),
            meta: ["source": .string("pksession"), "ref": .string(ref)]
        )
        item = try item.identified()

        // `err` is `layout` where Null gets the word wrong (plan, 8.2, rule 6).
        let events = try Typist().events(for: item, layouts: library)
        let null = try SystemName.null.play(CaseSetup(item: item, library: library, classifier: nil), events: events)
        let wrong = ScenarioBuilder.wrongTokens(item, null: null)
        if scenario == "clean", !wrong.isEmpty { return .failure(Failure(reason: .nullWrongInClean)) }
        if scenario == "slip" {
            guard !wrong.isEmpty else { return .failure(Failure(reason: .sameInBothLayouts)) }
            for position in wrong { item.tokens?[position].err = .layout }
        }
        return .success(Built(item: item, warmupWords: context.count))
    }

    /// The text of the strokes in a layout, or nil when format v1 cannot type it.
    static func render(_ keys: [KeyStroke], in map: LayoutMap) -> String? {
        var text = ""
        for stroke in keys {
            guard let typed = map.text(for: stroke), typed.count == 1, let character = typed.first,
                  !character.isWhitespace, LayoutLibrary.printableStroke(character, in: map) != nil
            else { return nil }
            text += typed
        }
        return text.isEmpty ? nil : text
    }

    /// What the person ended up with for a word before the one judged; nil
    /// when that is not known, and the warm-up stops there.
    private static func settled(_ word: ObservedWord, library: LayoutLibrary, names: [LayoutID: String]) -> Settled? {
        let trace = word.trace
        guard let typed = trace.layout else { return nil }
        func inLayout(_ layout: LayoutID) -> Settled? {
            guard let name = names[layout], let map = library[name], let text = render(trace.keys, in: map) else {
                return nil
            }
            return Settled(layout: layout, text: text)
        }
        switch word.outcome {
        case let .notJudged(skip):
            // Words typed where Perekey is blind to them (a password field) are not copied.
            switch skip {
            case .secureField, .secureInput, .unknownFocus: return nil
            default: return inLayout(typed)
            }
        case .kept:
            return inLayout(typed)
        case .keptThenRetyped:
            return word.retypedTo.flatMap(inLayout)
        case .keptThenRetypedAfterErasing, .cancelled:
            return nil
        case .acted:
            if case let .switched(to, _) = trace.action { return inLayout(to) }
            return nil
        case .actedThenUndone:
            switch (word.label, trace.action) {
            case (.falseSwitch, _), (.wrongCorrection, _): return inLayout(typed)
            case let (.right, .switched(to, _)): return inLayout(to)
            default: return nil
            }
        }
    }

    /// Whether the events between two words move the person elsewhere: a
    /// click, another focus, lost input, new layouts.
    private static func broken(_ run: ReplayRun, between first: Int, and second: Int) -> Bool {
        guard first + 1 < second else { return false }
        for step in run.steps[(first + 1)..<second] {
            switch step.event {
            case .click, .inputLost, .layoutsChanged: return true
            case let .focusChanged(_, change) where change == .moved: return true
            default: continue
            }
        }
        return false
    }
}
