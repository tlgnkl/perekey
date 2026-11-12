// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The small set that checks the stand against the real app (plan 12.4): a few cases of each `flow.*` suite
/// and of `tech.ruso`, taken the same way every time.
public enum FidelitySet {
    public struct Options: Sendable {
        /// Cases taken from each suite whose name starts with `flow.`. The plan: 20 of each.
        public var perFlowSuite = 20
        /// Cases taken from the other suites named here. The plan: 100 of `tech.ruso`.
        public var perSuite: [String: Int] = ["tech.ruso": 100]

        public init() {}
    }

    /// The cases to play: in each suite those whose ids end in the smallest hashes (the last 12 hex of the id
    /// is a hash of the content), so the choice depends on the content alone. Suites in name order,
    /// cases in hash order.
    public static func select(_ items: [EvalCase], options: Options = Options()) -> [EvalCase] {
        var bySuite: [String: [EvalCase]] = [:]
        for item in items { bySuite[item.suite, default: []].append(item) }
        var chosen: [EvalCase] = []
        for suite in bySuite.keys.sorted() {
            let count = suite.hasPrefix("flow.") ? options.perFlowSuite : options.perSuite[suite] ?? 0
            let ordered = bySuite[suite]!.sorted { (key($0), $0.id) < (key($1), $1.id) }
            chosen += ordered.prefix(count)
        }
        return chosen
    }

    private static func key(_ item: EvalCase) -> String { String(item.id.split(separator: "/").last ?? "") }
}

/// Machine against the real app on the same cases: the share whose final text differs (plan 12.4;
/// the aim is at most 1 %).
public struct FidelityReport: Sendable {
    public struct Difference: Sendable {
        public var id: String
        public var suite: String
        public var scenario: String
        public var split: String
        public var machine: String
        public var app: String?
        /// The texts differ (false when only the layout at the end does).
        public var textDiffers: Bool
        public var layoutDiffers: Bool
    }

    public struct Row: Sendable {
        public var played = 0
        public var differing = 0
    }

    /// Plan 12.4: at most this share of the played cases may differ.
    public static let aim = 0.01

    public var app: String
    public var skipped: [String: Int]
    public var aborted: String?
    public var played: Int
    /// By suite, in name order.
    public var bySuite: [(suite: String, row: Row)]
    public var differences: [Difference]
    /// Cases of the run that were not in the files given, or whose machine text is missing.
    public var unmatched: Int

    public var differingTexts: Int { differences.filter(\.textDiffers).count }
    public var rate: Double { played == 0 ? 0 : Double(differingTexts) / Double(played) }

    /// `machine`: the machine's text and layout (the id of the input source) by case id.
    public init(items: [EvalCase], machine: [String: (text: String, layout: String)], app run: AppRun, reveal: Bool) {
        app = run.app
        skipped = run.skipped
        aborted = run.aborted
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [String: Row] = [:]
        var differences: [Difference] = []
        var played = 0
        var unmatched = 0
        for entry in run.played {
            guard let item = byID[entry.id], let ours = machine[entry.id] else { unmatched += 1; continue }
            played += 1
            rows[item.suite, default: Row()].played += 1
            let textDiffers = Runner.sha256(Data(ours.text.utf8)) != entry.sha256
            let layoutDiffers = ours.layout != entry.layout
            guard textDiffers || layoutDiffers else { continue }
            if textDiffers { rows[item.suite]!.differing += 1 }
            let shown = item.split == .dev || reveal
            differences.append(Difference(
                id: entry.id, suite: item.suite, scenario: item.scenario, split: item.split.rawValue,
                machine: shown ? ours.text : AppRun.hidden, app: shown ? entry.text : nil,
                textDiffers: textDiffers, layoutDiffers: layoutDiffers
            ))
        }
        self.played = played
        self.unmatched = unmatched
        bySuite = rows.keys.sorted().map { ($0, rows[$0]!) }
        self.differences = differences
    }

    public func render(markdown: Bool = false) -> String {
        var lines: [String] = []
        func heading(_ text: String) { lines.append(markdown ? "## \(text)" : text) }
        lines.append(markdown ? "# Fidelity: Machine against \(app)" : "Fidelity: Machine against \(app)")
        lines.append("")
        let percent = String(format: "%.2f", rate * 100)
        lines.append("played \(played), final text differs in \(differingTexts) (\(percent) %), aim ≤ \(Int(Self.aim * 100)) %: "
            + (rate <= Self.aim ? "taken" : "NOT taken"))
        let skippedTotal = skipped.values.reduce(0, +)
        lines.append("not played \(skippedTotal)" + (skipped.isEmpty ? "" : ": "
            + skipped.keys.sorted().map { "\($0) \(skipped[$0]!)" }.joined(separator: ", ")))
        if unmatched > 0 { lines.append("not matched with the cases given: \(unmatched)") }
        if let aborted { lines.append("THE RUN STOPPED EARLY: \(aborted)") }
        lines.append("")
        heading("By suite")
        for (suite, row) in bySuite { lines.append("\(suite)\tplayed \(row.played)\tdiffer \(row.differing)") }
        lines.append("")
        heading("Differences")
        if differences.isEmpty { lines.append("none") }
        for difference in differences {
            var line = "\(difference.id)\t" + (difference.textDiffers ? "text" : "layout only")
                + (difference.textDiffers && difference.layoutDiffers ? ", layout" : "")
            if let app = difference.app {
                line += "\n  machine: \(difference.machine.debugDescription)\n  app:     \(app.debugDescription)"
            } else {
                line += "\n  (test part: words hidden, --reveal-test shows them)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension AppRun {
    /// What the report says in place of the machine's words of the part `test`.
    static let hidden = RunFiles.hiddenText
}
