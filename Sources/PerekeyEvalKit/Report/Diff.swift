// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The options of `diff`.
public struct DiffOptions: Sendable {
    /// How many cases to list under «Сломано» and «Починено» (`--list`).
    public var list = 20
    /// Words of the test part (`--reveal-test`, rule 2.8).
    public var revealTest = false

    public init() {}
}

/// A token whose outcome changed between two runs.
public struct TokenChange: Hashable, Sendable, Codable {
    public var id: String
    /// The token's number among the tokens of `want`; nil for a case scored as a whole.
    public var index: Int?
    /// The words, or `(test)`.
    public var want: String
    public var before: String
    public var after: String
}

/// One metric of the comparison: totals over the common cases, and the
/// cases that changed each way, with the exact McNemar p (plan, 10.3).
public struct DiffRow: Hashable, Sendable, Codable {
    public var name: String
    public var a: Int
    public var b: Int
    public var better: Int
    public var worse: Int
    public var p: Double
}

public struct DiffData: Hashable, Sendable, Codable {
    public static let schema = 1

    public var schema = DiffData.schema
    public var a: String
    public var b: String
    public var common: Int
    public var onlyA: Int
    public var onlyB: Int
    public var rows: [DiffRow]
    public var broken: [TokenChange]
    public var fixed: [TokenChange]
    /// Test part: the number of cases and the suites they belong to, no words.
    public var brokenTest: [String: Int]
    public var fixedTest: [String: Int]
    public var notes: [String]
}

public enum DiffBuilder {
    /// The outcome letters that are right: ok and fixed.
    private static let right: Set<Character> = ["o", "F"]
    private static let names: [Character: String] = ["o": "ok", "F": "fixed", "H": "harm", "M": "miss", "B": "botched",
                                                     "D": "disputed", "S": "spill"]

    public static func build(_ a: RunData, _ b: RunData, options: DiffOptions = DiffOptions()) throws -> DiffData {
        guard a.scorer == b.scorer else {
            throw EvalError.input("the runs were scored by different scorers (\(a.scorer) and \(b.scorer)); play them again")
        }
        var notes: [String] = []
        if a.info.lexicon != b.info.lexicon || a.info.seen != b.info.seen {
            notes.append("лексикон или списки data/ у прогонов разные: исходы «спорно» и «тихо» сравнимы не полностью")
        }
        if a.info.testRevealed != b.info.testRevealed { notes.append("тест раскрыт только в одном из прогонов") }
        let rowsA = Dictionary(a.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rowsB = Dictionary(b.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let common = rowsA.keys.filter { rowsB[$0] != nil }.sorted()
        let eventsA = index(a.events), eventsB = index(b.events)

        var sums: [(String, KeyPath<Metrics, Int>, Int, Int, Int, Int)] = []
        let measures: [(String, KeyPath<Metrics, Int>)] = [("вред", \.harm), ("пропуск", \.miss), ("порча", \.botched),
                                                           ("тихий вред", \.silent), ("спорно", \.disputed)]
        for (name, path) in measures {
            var total = (0, 0, 0, 0)
            for id in common {
                let before = rowsA[id]!.metrics[keyPath: path], after = rowsB[id]!.metrics[keyPath: path]
                total.0 += before
                total.1 += after
                if after < before { total.2 += 1 } else if after > before { total.3 += 1 }
            }
            sums.append((name, path, total.0, total.1, total.2, total.3))
        }
        let rows = sums.map {
            DiffRow(name: $0.0, a: $0.2, b: $0.3, better: $0.4, worse: $0.5, p: Stats.mcNemar(better: $0.4, worse: $0.5))
        }

        var broken: [TokenChange] = [], fixed: [TokenChange] = []
        var brokenTest: [String: Int] = [:], fixedTest: [String: Int] = [:]
        for id in common {
            let rowA = rowsA[id]!, rowB = rowsB[id]!
            let hide = rowB.split == "test" && !options.revealTest
            var brokeHere = false, fixedHere = false
            func shown(_ text: String) -> String { hide ? RunFiles.hiddenText : text }
            func record(_ list: inout [TokenChange], _ change: TokenChange, test: inout [String: Int], flag: inout Bool) {
                if hide {
                    if !flag { test[rowB.suite, default: 0] += 1 }
                    flag = true
                } else {
                    list.append(change)
                }
            }
            let lettersA = a.outcomes[id]?.letters ?? "", lettersB = b.outcomes[id]?.letters ?? ""
            if lettersA.isEmpty, lettersB.isEmpty {
                // Scored as a whole: the text is right or not.
                if rowA.metrics.exact != rowB.metrics.exact {
                    let line = eventsB[id]?.wholeCase ?? eventsA[id]?.wholeCase
                    let change = TokenChange(id: id, index: nil, want: shown(line?.want ?? "?"),
                                             before: rowA.metrics.exact == 1 ? "exact" : "fail",
                                             after: rowB.metrics.exact == 1 ? "exact" : "fail")
                    if rowB.metrics.exact == 0 { record(&broken, change, test: &brokenTest, flag: &brokeHere) }
                    else { record(&fixed, change, test: &fixedTest, flag: &fixedHere) }
                }
                continue
            }
            guard lettersA.count == lettersB.count else {
                notes.append("случай \(id) разной длины в двух прогонах: пропущен")
                continue
            }
            for (index, (x, y)) in zip(lettersA, lettersB).enumerated() where x != y {
                let wasRight = right.contains(x), isRight = right.contains(y)
                guard wasRight != isRight, y != "D", x != "D" else { continue }
                let word = (eventsB[id]?[index] ?? eventsA[id]?[index])?.want ?? "?"
                let change = TokenChange(id: id, index: index, want: shown(word), before: names[x] ?? String(x),
                                         after: names[y] ?? String(y))
                if isRight { record(&fixed, change, test: &fixedTest, flag: &fixedHere) }
                else { record(&broken, change, test: &brokenTest, flag: &brokeHere) }
            }
        }
        return DiffData(a: label(a), b: label(b), common: common.count, onlyA: rowsA.count - common.count,
                        onlyB: rowsB.count - common.count, rows: rows, broken: broken, fixed: fixed,
                        brokenTest: brokenTest, fixedTest: fixedTest, notes: notes)
    }

    private static func label(_ run: RunData) -> String { "\(run.info.system)@\(run.info.commit)" }

    /// The events of a run by case, then by token number (a case scored as a whole: position 0).
    private static func index(_ events: [RunData.Event]) -> [String: [Int: RunData.Event]] {
        var result: [String: [Int: RunData.Event]] = [:]
        for event in events { result[event.id, default: [:]][event.index ?? 0] = event }
        return result
    }
}

extension Dictionary where Key == Int, Value == RunData.Event {
    /// The event of a case scored as a whole (position 0).
    var wholeCase: RunData.Event? { self[0] ?? values.first }
}

enum DiffRender {
    static func text(_ data: DiffData, list: Int, markdown: Bool = false) -> String {
        var out = "\(markdown ? "# " : "")A \(data.a) → B \(data.b), случаев \(Fmt.int(data.common)) общих"
        if data.onlyA + data.onlyB > 0 { out += " (только в A: \(Fmt.int(data.onlyA)), только в B: \(Fmt.int(data.onlyB)))" }
        out += "\n\n"
        let table = ReportTable(
            title: nil, columns: ["", "A", "B", "лучше", "хуже", "p"],
            rows: data.rows.map { row in
                [row.name, Fmt.int(row.a), Fmt.int(row.b), Fmt.int(row.better), Fmt.int(row.worse),
                 row.better + row.worse == 0 ? "—" : row.p < 0.001 ? "<0,001" : Fmt.number(row.p, digits: 3)]
            })
        out += markdown ? mdTable(table) : plain(table)
        out += "\n" + section("Сломано (dev)", data.broken, list: list)
        if !data.brokenTest.isEmpty { out += testLine("Сломано (test)", data.brokenTest) }
        out += "\n" + section("Починено (dev)", data.fixed, list: list)
        if !data.fixedTest.isEmpty { out += testLine("Починено (test)", data.fixedTest) }
        for note in data.notes { out += "\nПримечание: \(note)." }
        return out + "\n"
    }

    private static func section(_ title: String, _ changes: [TokenChange], list: Int) -> String {
        guard !changes.isEmpty else { return "\(title): нет\n" }
        var out = "\(title): \(changes.count)\n"
        for change in changes.prefix(list) {
            out += "  \(change.id)" + (change.index.map { " #\($0)" } ?? "") + "  «\(change.want)»  было \(change.before) → стало \(change.after)\n"
        }
        if changes.count > list { out += "  …и ещё \(changes.count - list)\n" }
        return out
    }

    private static func testLine(_ title: String, _ suites: [String: Int]) -> String {
        let total = suites.values.reduce(0, +)
        let list = suites.keys.sorted().map { "\($0) ×\(suites[$0]!)" }.joined(separator: ", ")
        return "\(title): \(total) \(total == 1 ? "случай" : "случаев"), наборы: \(list)\n"
    }

    private static func plain(_ table: ReportTable) -> String {
        let widths = table.columns.indices.map { column in
            ([table.columns[column]] + table.rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: max(0, widths[column] - cell.count))
                return column == 0 ? cell + pad : pad + cell
            }.joined(separator: "  ")
        }
        return ([line(table.columns)] + table.rows.map(line)).joined(separator: "\n") + "\n"
    }

    private static func mdTable(_ table: ReportTable) -> String {
        "| " + table.columns.joined(separator: " | ") + " |\n|---|" + String(repeating: "---:|", count: table.columns.count - 1) + "\n"
            + table.rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n") + "\n"
    }
}
