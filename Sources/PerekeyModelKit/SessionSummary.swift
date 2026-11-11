// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The numbers of `perekey-eval replay words` (docs/classifier.md, «Замер
/// на живых сессиях»): counts only, no word. Bundle IDs name apps, not text.
public struct SessionSummary: Codable, Equatable, Sendable {
    public struct KindCount: Codable, Equatable, Sendable {
        public var count = 0
        public var undone = 0

        public init(count: Int = 0, undone: Int = 0) {
            self.count = count
            self.undone = undone
        }
    }

    /// The counts of one reason or one app.
    public struct Slice: Codable, Equatable, Sendable {
        public var words = 0
        public var switches = 0
        public var falseStrong = 0
        public var falseUnclear = 0
        public var misses = 0
    }

    public var segments = 0
    public var events = 0
    /// Segments where the exact replay answered otherwise than the recording.
    public var mismatches = 0
    public var words = 0
    public var judged = 0
    /// Words not judged, by `JudgeTrace.Skip`.
    public var notJudged: [String: Int] = [:]
    public var switches = 0
    public var earlySwitches = 0
    public var falseStrong = 0
    public var falseUnclear = 0
    /// Switches the user undid and then put back with the shortcut.
    public var confirmedSwitches = 0
    public var missesByHand = 0
    public var missesErased = 0
    /// Word corrections in their own layout, by `Correction.Kind`.
    public var corrections: [String: KindCount] = [:]
    /// Retypes the system layer cancelled: the text before the caret was not the word.
    public var retypesCancelled = 0
    /// The fence let input go because its time ran out.
    public var fenceExpired = 0
    /// Held keys that never came back as replayed.
    public var replaysMissing = 0
    /// Judged words by `Classifier.Reason` of their decision.
    public var byReason: [String: Slice] = [:]
    public var byApp: [String: Slice] = [:]

    public init() {}

    public mutating func add(_ run: ReplayRun, words observed: [ObservedWord]) {
        segments += 1
        events += run.steps.count { $0.recorded != nil }
        if run.mismatch != nil { mismatches += 1 }
        var held = 0
        var replayed = 0
        for step in run.steps {
            if case .retypeCancelled = step.event { retypesCancelled += 1 }
            if step.fenceExpired { fenceExpired += 1 }
            if step.output.disposition == .hold, step.event.isUserInput { held += 1 }
            switch step.event {
            case let .key(key, _) where key.origin == .replayed: replayed += 1
            case let .flagsChanged(_, _, origin, _, _) where origin == .replayed: replayed += 1
            default: break
            }
        }
        replaysMissing += max(0, held - replayed)
        for word in observed {
            add(word)
        }
    }

    private mutating func add(_ word: ObservedWord) {
        words += 1
        var slice = Slice(words: 1)
        switch word.trace.action {
        case let .notJudged(skip):
            notJudged[skip.rawValue, default: 0] += 1
        case let .switched(_, early):
            judged += 1
            if word.outcome != .cancelled {
                switches += 1
                slice.switches = 1
                if early { earlySwitches += 1 }
            }
        case let .corrected(kind):
            judged += 1
            if word.outcome != .cancelled {
                corrections["\(kind)", default: KindCount()].count += 1
                if case .actedThenUndone = word.outcome { corrections["\(kind)", default: KindCount()].undone += 1 }
            }
        case .kept:
            judged += 1
        }
        switch (word.label, word.strength) {
        case (.falseSwitch, _):
            falseStrong += 1
            slice.falseStrong = 1
        case (.unclear, _):
            falseUnclear += 1
            slice.falseUnclear = 1
        case (.right, .strong?):
            confirmedSwitches += 1
        case (.miss, _):
            if word.outcome == .keptThenRetyped { missesByHand += 1 } else { missesErased += 1 }
            slice.misses = 1
        default:
            break
        }
        if let reason = word.trace.decision?.reason { byReason["\(reason)", default: Slice()].add(slice) }
        byApp[word.trace.app ?? "(unknown)", default: Slice()].add(slice)
    }

    /// The table, as `replay words` prints it.
    public func render() -> String {
        var lines: [String] = []
        let perThousand = { (count: Int) in words == 0 ? "–" : String(format: "%.1f", Double(count) * 1000 / Double(words)) }
        let share = { (count: Int) in switches == 0 ? "–" : String(format: "%.1f %%", Double(count) * 100 / Double(switches)) }
        lines.append("segments \(segments), events \(events), segments that differ from the recording \(mismatches)")
        let skipped = JudgeTrace.Skip.allCases.compactMap { skip in
            notJudged[skip.rawValue].map { "\(skip.rawValue) \($0)" }
        }
        lines.append("words \(words): judged \(judged), not judged \(words - judged)"
            + (skipped.isEmpty ? "" : " (\(skipped.joined(separator: ", ")))"))
        lines.append("switches \(switches): inside the word \(earlySwitches), at its end \(switches - earlySwitches)")
        lines.append("false switches: strong \(falseStrong) (\(share(falseStrong)) of switches, \(perThousand(falseStrong)) per 1000 words), "
            + "unclear \(falseUnclear) (\(share(falseUnclear)), \(perThousand(falseUnclear)) per 1000 words); "
            + "undone and put back \(confirmedSwitches)")
        lines.append("misses: retyped by hand \(missesByHand) (\(perThousand(missesByHand)) per 1000 words), "
            + "erased and typed again \(missesErased) (\(perThousand(missesErased)) per 1000 words)")
        let kinds = corrections.keys.sorted().map { "\($0) \(corrections[$0]!.count) (undone \(corrections[$0]!.undone))" }
        lines.append("corrections: " + (kinds.isEmpty ? "none" : kinds.joined(separator: ", ")))
        lines.append("retypes: cancelled by the text check \(retypesCancelled), fence ran out \(fenceExpired), "
            + "held keys not replayed \(replaysMissing)")
        lines.append("")
        lines.append(Self.table("reason", byReason))
        lines.append("")
        lines.append(Self.table("app", byApp))
        return lines.joined(separator: "\n")
    }

    private static func table(_ title: String, _ slices: [String: Slice]) -> String {
        let width = max(title.count, slices.keys.map(\.count).max() ?? 0)
        let pad = { (text: String) in text.padding(toLength: width, withPad: " ", startingAt: 0) }
        var lines = ["\(pad(title))  words  switches  false  unclear  misses"]
        for key in slices.keys.sorted(by: { (slices[$0]!.words, $1) > (slices[$1]!.words, $0) }) {
            let slice = slices[key]!
            lines.append(pad(key) + String(format: "  %5d  %8d  %5d  %7d  %6d", slice.words, slice.switches,
                                           slice.falseStrong, slice.falseUnclear, slice.misses))
        }
        return lines.joined(separator: "\n")
    }
}

extension SessionSummary.Slice {
    mutating func add(_ other: Self) {
        words += other.words
        switches += other.switches
        falseStrong += other.falseStrong
        falseUnclear += other.falseUnclear
        misses += other.misses
    }
}

/// The typed words, for `--show-words` only: in the terminal, never in a file.
public enum SessionReport {
    /// One line per labelled word: the keys as typed, what they read in the
    /// other layouts, and the outcome.
    public static func words(_ words: [ObservedWord], layouts: [LayoutMap]) -> String {
        words.filter { $0.label != .none }.map { word in
            let maps = Dictionary(layouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let typed = word.trace.layout.flatMap { maps[$0] }.map { text(word.trace.keys, in: $0) } ?? "?"
            let others = layouts.filter { $0.id != word.trace.layout }.map { text(word.trace.keys, in: $0) }
            let strength = word.strength.map { " \($0.rawValue)" } ?? ""
            return "\(typed) (\(others.joined(separator: ", "))): \(word.label.rawValue)\(strength), \(word.outcome)"
        }.joined(separator: "\n")
    }

    static func text(_ keys: [KeyStroke], in map: LayoutMap) -> String {
        keys.map { map.text(for: $0) ?? "·" }.joined()
    }
}
