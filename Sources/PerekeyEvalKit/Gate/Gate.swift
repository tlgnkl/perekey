// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a bar came out.
public enum GateVerdict: String, Hashable, Sendable, Codable {
    case pass, fail
    /// The count grew, and `accepted` names it: a deliberate exception.
    case accepted
    /// The count grew in a stand pull request: shown, not a bar (docs/eval.md, «Планки»).
    case shown
    /// Nothing to read: no such suite in the run, or no base.
    case skipped
}

/// A case that moved a count, with its numbers.
public struct GateCase: Hashable, Sendable, Codable {
    public var id: String
    public var head: Double
    public var base: Double?
}

/// One bar applied to one suite or one profile.
public struct GateCheck: Hashable, Sendable, Codable {
    public var kind: String
    public var metric: String
    public var scope: String
    /// `down` or `up`.
    public var direction: String
    public var head: Double
    public var base: Double?
    public var verdict: GateVerdict
    public var note: String?
    public var accepted: GateFile.Accepted?
    /// The cases that broke the bar, by id; at most `Gate.Options.listed`.
    public var cases: [GateCase]
    /// Cases that broke it and are not listed.
    public var more: Int
}

public struct GateResult: Hashable, Sendable, Codable {
    public static let schema = 1

    public var schema = GateResult.schema
    public var head: String
    public var base: String?
    /// The pull request changes the stand and not the core: `noWorse` is shown, not a bar.
    public var standPullRequest: Bool
    public var checks: [GateCheck]
    public var targets: [GateFile.Target]
    public var accepted: [GateFile.Accepted]
    public var notes: [String]

    /// Whether every bar is taken.
    public var passed: Bool { !checks.contains { $0.verdict == .fail } }
}

public enum Gate {
    public struct Options: Sendable {
        /// How many broken cases a bar lists (`--list`). Not a bar itself: the diff lists the rest.
        public var listed = 20
        /// Two sums of weighted counts are the same below this difference. Weighted
        /// sums of integers are exact up to the rounding of the weights.
        public var epsilon = 1e-9
        public var standPullRequest = false

        public init() {}
    }

    /// Applies the bars of `gates` to `head`, and for `noWorse` to `head` against `base`.
    /// `statusOf` maps a case id to its `meta.status` for the rules that name one.
    public static func check(_ gates: GateFile, head: RunData, base: RunData?, profiles: ProfileFile?,
                             statusOf: [String: String], options: Options = Options()) -> GateResult
    {
        var checks: [GateCheck] = []
        var notes: [String] = []
        // The rows stay in their table: a full run has millions of them, and the bars read a few counters of each.
        let headRows = head.rows
        let headSuites = headRows.distinctSuites
        var rowsOfSuite: [Int: [Int]] = [:]
        if !gates.zero.isEmpty {
            for index in headRows.indices { rowsOfSuite[headRows.suiteNumber(at: index), default: []].append(index) }
        }
        let numberOfSuite = Dictionary(headRows.suiteNames.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        for rule in gates.zero {
            let suites = headSuites.filter { GateMetric.matches(rule.suite!, $0) }
            guard !suites.isEmpty else {
                // A bar that reads nothing is not taken, unless the suite may be missing (`optional`).
                var check = skipped("zero", rule, "в прогоне нет набора \(rule.suite!)")
                if rule.optional != true { check.verdict = .fail }
                checks.append(check)
                continue
            }
            let value = headRows.counter(GateMetric.counts[rule.metric]!)
            for suite in suites {
                var total = 0
                var broken: [Int] = []
                for index in rowsOfSuite[numberOfSuite[suite]!] ?? []
                where rule.status == nil || statusOf[headRows.id(at: index)] == rule.status
                {
                    let count = value(index)
                    total += count
                    if count > 0 { broken.append(index) }
                }
                broken.sort { headRows.id(at: $0) < headRows.id(at: $1) }
                var check = GateCheck(kind: "zero", metric: rule.metric, scope: suite, direction: "down", head: Double(total),
                                      base: nil, verdict: total == 0 ? .pass : .fail, note: rule.status.map { "статус \($0)" },
                                      accepted: nil, cases: [], more: 0)
                if total != 0 {
                    check.cases = broken.prefix(options.listed).map { GateCase(id: headRows.id(at: $0), head: Double(value($0)), base: nil) }
                    check.more = max(0, broken.count - options.listed)
                    apply(gates.accepted, to: &check)
                }
                checks.append(check)
            }
        }

        if let base {
            let baseRows = base.rows
            // The first row of each id; a head row is «common» when the base has its id, and its base row is the first of that id.
            func firstRows(_ table: RowTable) -> [String: Int] {
                var result: [String: Int] = [:]
                result.reserveCapacity(table.count)
                for index in table.indices where result[table.id(at: index)] == nil { result[table.id(at: index)] = index }
                return result
            }
            let baseFirst = firstRows(baseRows)
            let headFirst = firstRows(headRows)
            let commonCount = headFirst.keys.reduce(0) { baseFirst[$1] != nil ? $0 + 1 : $0 }
            var pairs: [(head: Int, base: Int)] = []
            for index in headRows.indices {
                if let other = baseFirst[headRows.id(at: index)] { pairs.append((index, other)) }
            }
            var headCommonSuites = Set<Int>(), baseCommonSuites = Set<Int>()
            for pair in pairs { headCommonSuites.insert(headRows.suiteNumber(at: pair.head)) }
            for index in baseRows.indices where headFirst[baseRows.id(at: index)] != nil {
                baseCommonSuites.insert(baseRows.suiteNumber(at: index))
            }
            let common = Set(headCommonSuites.map { headRows.suiteNames[$0] })
                .intersection(baseCommonSuites.map { baseRows.suiteNames[$0] }).sorted()
            if headRows.count != commonCount || baseRows.count != commonCount {
                notes.append("общих случаев \(commonCount); только в голове \(headRows.count - commonCount), только в базе \(baseRows.count - commonCount)")
            }
            // A head that lost cases of the base compares less than the base: the cases vanished, the bars did not see them.
            // A stand pull request may drop or rename cases; it is only noted above.
            let lost = baseRows.indices.map { baseRows.id(at: $0) }.filter { headFirst[$0] == nil }.sorted()
            if !lost.isEmpty, !options.standPullRequest {
                checks.append(GateCheck(kind: "coverage", metric: "cases", scope: "all", direction: "down", head: Double(commonCount),
                                        base: Double(baseRows.count), verdict: .fail, note: "у головы нет случаев базы", accepted: nil,
                                        cases: lost.prefix(options.listed).map { GateCase(id: $0, head: 0, base: 1) },
                                        more: max(0, lost.count - options.listed)))
            }
            for rule in gates.noWorse {
                let path = GateMetric.counts[rule.metric]!
                let direction = rule.up ? "up" : "down"
                var groups: [(scope: String, weights: [String: Double])] = []
                if let pattern = rule.suite {
                    let suites = common.filter { GateMetric.matches(pattern, $0) }
                    guard !suites.isEmpty else {
                        checks.append(skipped("noWorse", rule, "нет набора \(pattern) в обоих прогонах"))
                        continue
                    }
                    groups = suites.map { ($0, [$0: 1.0]) }
                } else {
                    guard let profiles else {
                        checks.append(skipped("noWorse", rule, "нет файла профилей"))
                        continue
                    }
                    let names = profiles.profiles.keys.sorted().filter { GateMetric.matches(rule.profile!, $0) }
                    guard !names.isEmpty else {
                        checks.append(skipped("noWorse", rule, "нет профиля \(rule.profile!)"))
                        continue
                    }
                    for name in names {
                        let present = profiles.profiles[name]!.filter { common.contains($0.key) }
                        guard !present.isEmpty else {
                            checks.append(skipped("noWorse", rule, "в прогонах нет ни одного набора профиля \(name)", scope: "profile:\(name)"))
                            continue
                        }
                        let sum = present.values.reduce(0, +)
                        groups.append(("profile:\(name)", present.mapValues { $0 / sum }))
                    }
                }
                let headValue = headRows.counter(path), baseValue = baseRows.counter(path)
                for (scope, weights) in groups {
                    let weightOfNumber = headRows.suiteNames.map { weights[$0] }
                    var headSum = 0.0, baseSum = 0.0
                    var moved: [(index: Int, head: Double, base: Double)] = []
                    for pair in pairs {
                        guard let weight = weightOfNumber[headRows.suiteNumber(at: pair.head)] else { continue }
                        let h = Double(headValue(pair.head)), b = Double(baseValue(pair.base))
                        headSum += weight * h
                        baseSum += weight * b
                        if rule.up ? h < b : h > b { moved.append((pair.head, h, b)) }
                    }
                    let broke = rule.up ? baseSum - headSum > options.epsilon : headSum - baseSum > options.epsilon
                    var check = GateCheck(kind: "noWorse", metric: rule.metric, scope: scope, direction: direction, head: headSum,
                                          base: baseSum, verdict: broke ? .fail : .pass, note: nil, accepted: nil, cases: [], more: 0)
                    if broke {
                        moved.sort { headRows.id(at: $0.index) < headRows.id(at: $1.index) }
                        check.cases = moved.prefix(options.listed).map { GateCase(id: headRows.id(at: $0.index), head: $0.head, base: $0.base) }
                        check.more = max(0, moved.count - options.listed)
                        apply(gates.accepted, to: &check)
                        if check.verdict == .fail, options.standPullRequest { check.verdict = .shown }
                    }
                    checks.append(check)
                }
            }
        } else if !gates.noWorse.isEmpty {
            notes.append("базы нет: планки noWorse не проверены")
            for rule in gates.noWorse { checks.append(skipped("noWorse", rule, "базы нет")) }
        }
        return GateResult(head: label(head), base: base.map(label), standPullRequest: options.standPullRequest, checks: checks,
                          targets: gates.targets, accepted: gates.accepted, notes: notes)
    }

    private static func label(_ run: RunData) -> String { "\(run.info.system)@\(run.info.commit)" }

    private static func skipped(_ kind: String, _ rule: GateFile.Rule, _ note: String, scope: String? = nil) -> GateCheck {
        GateCheck(kind: kind, metric: rule.metric, scope: scope ?? rule.scope, direction: rule.up ? "up" : "down", head: 0,
                  base: nil, verdict: .skipped, note: note, accepted: nil, cases: [], more: 0)
    }

    private static func apply(_ accepted: [GateFile.Accepted], to check: inout GateCheck) {
        guard let entry = accepted.first(where: { $0.metric == check.metric && GateMetric.matches($0.scope, check.scope) }) else {
            return
        }
        check.verdict = .accepted
        check.accepted = entry
    }
}

/// Which pull requests change the stand and not the core (docs/eval.md, «Планки»): those whose every changed
/// file lies in the stand. A white list: a file nobody named makes the pull request a core one.
public enum StandChange {
    /// Folders end with `/`; the rest are files.
    public static let paths = ["eval/", "Sources/PerekeyEvalKit/", "Sources/PerekeyDesk/", "Sources/perekey-eval/",
                               "Tests/PerekeyEvalKitTests/", "docs/", "scripts/quality.sh"]

    public static func isStand(_ files: [String]) -> Bool {
        let names = files.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return !names.isEmpty && names.allSatisfy { name in
            paths.contains { $0.hasSuffix("/") ? name.hasPrefix($0) : name == $0 }
        }
    }
}

public enum GateRender {
    public static func text(_ result: GateResult, markdown: Bool = false) -> String {
        var out = markdown ? "## Планки\n\n" : ""
        out += "Голова \(result.head)" + (result.base.map { ", база \($0)" } ?? ", базы нет") + "\n"
        if result.standPullRequest {
            out += "PR стенда: noWorse печатается и не гейтит; гейтят zero, самопроверка и тесты.\n"
        }
        out += "\n"
        let title: [GateVerdict: String] = [.pass: "ok", .fail: "НЕ ВЗЯТА", .accepted: "принято", .shown: "не гейтит",
                                            .skipped: "пропущена"]
        let rows = result.checks.map { check -> [String] in
            let numbers = check.kind == "zero" ? number(check.head)
                : "\(number(check.base ?? 0)) → \(number(check.head))\(check.direction == "up" ? " (не меньше)" : "")"
            return [check.kind, check.scope, check.metric, check.verdict == .skipped ? "—" : numbers,
                    title[check.verdict]! + (check.note.map { " (\($0))" } ?? "")]
        }
        out += table(["планка", "набор", "метрика", "число", "итог"], rows, markdown: markdown)
        let broken = result.checks.filter { [.fail, .shown, .accepted].contains($0.verdict) }
        for check in broken {
            out += "\n\(title[check.verdict]!): \(check.kind) \(check.metric) \(check.scope)"
            if let entry = check.accepted { out += " — \(entry.reason) (PR #\(entry.pr))" }
            out += "\n"
            for item in check.cases {
                out += "  \(item.id)  " + (item.base.map { "было \(number($0)) → стало \(number(item.head))" } ?? "\(number(item.head))")
                    + "\n"
            }
            if check.more > 0 { out += "  …и ещё \(check.more)\n" }
            if !check.cases.isEmpty {
                out += "  Слова случая: perekey-eval case --cases <файл> --id <id> --model .build/model; сравнение: perekey-eval diff\n"
            }
        }
        out += "\nПринятые исключения (accepted): "
        if result.accepted.isEmpty {
            out += "нет\n"
        } else {
            out += "\(result.accepted.count)\n"
            for entry in result.accepted { out += "  \(entry.metric) \(entry.scope): \(entry.reason) (PR #\(entry.pr))\n" }
        }
        if !result.targets.isEmpty {
            out += "\nЦели (печатаются, не гейтят):\n"
            for target in result.targets {
                out += "  \(target.metric) \(target.scope): \(number(target.value))" + (target.note.map { " — \($0)" } ?? "") + "\n"
            }
        }
        for note in result.notes { out += "\nПримечание: \(note).\n" }
        let counts = Dictionary(grouping: result.checks, by: \.verdict).mapValues(\.count)
        out += "\nИтог: " + (result.passed ? "планки взяты" : "ПЛАНКА НЕ ВЗЯТА")
            + " (ok \(counts[.pass] ?? 0), не взято \(counts[.fail] ?? 0), принято \(counts[.accepted] ?? 0), "
            + "не гейтит \(counts[.shown] ?? 0), пропущено \(counts[.skipped] ?? 0))\n"
        return out
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.4f", value)
    }

    private static func table(_ columns: [String], _ rows: [[String]], markdown: Bool) -> String {
        if markdown {
            return "| " + columns.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: columns.count) + "\n"
                + rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n") + "\n"
        }
        let widths = columns.indices.map { column in ([columns[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0 }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { $1 + String(repeating: " ", count: max(0, widths[$0] - $1.count)) }.joined(separator: "  ")
        }
        return ([line(columns)] + rows.map(line)).joined(separator: "\n") + "\n"
    }
}
