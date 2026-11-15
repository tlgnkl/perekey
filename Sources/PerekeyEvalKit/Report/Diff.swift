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
        // The rows stay in their tables, the events on disk: a full run has millions of cases and gigabytes of events.
        // Both tables by id, and a walk over the two orders: the common ids come sorted, as the report lists them.
        // Of rows with one id the first is the case; the outcome letters of the last are the ones of the id.
        let idsA = a.rows, idsB = b.rows
        let orderA = idsA.orderedByID(), orderB = idsB.orderedByID()
        var pairs: [(a: Int32, b: Int32, lastA: Int32, lastB: Int32)] = []
        var distinctA = 0, distinctB = 0
        do {
            func groupEnd(_ order: [Int32], _ table: RowTable, from start: Int) -> Int {
                let id = table.id(at: Int(order[start]))
                var end = start + 1
                while end < order.count, table.id(at: Int(order[end])) == id { end += 1 }
                return end
            }
            var i = 0, j = 0
            while i < orderA.count || j < orderB.count {
                let endA = i < orderA.count ? groupEnd(orderA, idsA, from: i) : i
                let endB = j < orderB.count ? groupEnd(orderB, idsB, from: j) : j
                if i < orderA.count, j < orderB.count {
                    let x = idsA.id(at: Int(orderA[i])), y = idsB.id(at: Int(orderB[j]))
                    if x == y {
                        pairs.append((orderA[i], orderB[j], orderA[endA - 1], orderB[endB - 1]))
                        distinctA += 1
                        distinctB += 1
                        i = endA
                        j = endB
                    } else if x < y {
                        distinctA += 1
                        i = endA
                    } else {
                        distinctB += 1
                        j = endB
                    }
                } else if i < orderA.count {
                    distinctA += 1
                    i = endA
                } else {
                    distinctB += 1
                    j = endB
                }
            }
        }
        let common = pairs.count

        var sums: [(String, KeyPath<Metrics, Int>, Int, Int, Int, Int)] = []
        let measures: [(String, KeyPath<Metrics, Int>)] = [("вред", \.harm), ("пропуск", \.miss), ("порча", \.botched),
                                                           ("тихий вред", \.silent), ("спорно", \.disputed)]
        for (name, path) in measures {
            let valueA = a.rows.counter(path), valueB = b.rows.counter(path)
            var total = (0, 0, 0, 0)
            for pair in pairs {
                let before = valueA(Int(pair.a)), after = valueB(Int(pair.b))
                total.0 += before
                total.1 += after
                if after < before { total.2 += 1 } else if after > before { total.3 += 1 }
            }
            sums.append((name, path, total.0, total.1, total.2, total.3))
        }
        let rows = sums.map {
            DiffRow(name: $0.0, a: $0.2, b: $0.3, better: $0.4, worse: $0.5, p: Stats.mcNemar(better: $0.4, worse: $0.5))
        }

        // The words of the changes are in the events. The changes come first, with `want` empty; the events of their
        // cases are read once after, and only theirs are kept.
        enum Lookup { case token(Int), whole }
        var broken: [TokenChange] = [], fixed: [TokenChange] = []
        var brokenLookups: [Lookup] = [], fixedLookups: [Lookup] = []
        var brokenTest: [String: Int] = [:], fixedTest: [String: Int] = [:]
        let exactA = a.rows.counter(\.exact), exactB = b.rows.counter(\.exact)
        for pair in pairs {
            let indexA = Int(pair.a), indexB = Int(pair.b)
            let id = idsA.id(at: indexA)
            let splitB = b.rows.split(at: indexB), suiteB = b.rows.suite(at: indexB)
            let hide = splitB == "test" && !options.revealTest
            var brokeHere = false, fixedHere = false
            func record(_ list: inout [TokenChange], _ lookups: inout [Lookup], _ change: TokenChange, _ lookup: Lookup,
                        test: inout [String: Int], flag: inout Bool)
            {
                if hide {
                    if !flag { test[suiteB, default: 0] += 1 }
                    flag = true
                } else {
                    list.append(change)
                    lookups.append(lookup)
                }
            }
            let lettersA = a.outcomeLetters.isEmpty ? "" : a.outcomeLetters[Int(pair.lastA)]
            let lettersB = b.outcomeLetters.isEmpty ? "" : b.outcomeLetters[Int(pair.lastB)]
            if lettersA.isEmpty, lettersB.isEmpty {
                // Scored as a whole: the text is right or not.
                if exactA(indexA) != exactB(indexB) {
                    let change = TokenChange(id: id, index: nil, want: "", before: exactA(indexA) == 1 ? "exact" : "fail",
                                             after: exactB(indexB) == 1 ? "exact" : "fail")
                    if exactB(indexB) == 0 { record(&broken, &brokenLookups, change, .whole, test: &brokenTest, flag: &brokeHere) }
                    else { record(&fixed, &fixedLookups, change, .whole, test: &fixedTest, flag: &fixedHere) }
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
                let change = TokenChange(id: id, index: index, want: "", before: names[x] ?? String(x),
                                         after: names[y] ?? String(y))
                if isRight { record(&fixed, &fixedLookups, change, .token(index), test: &fixedTest, flag: &fixedHere) }
                else { record(&broken, &brokenLookups, change, .token(index), test: &brokenTest, flag: &brokeHere) }
            }
        }
        let wanted = Set(broken.map(\.id)).union(fixed.map(\.id))
        let eventsA = try a.events(of: wanted), eventsB = try b.events(of: wanted)
        func fill(_ list: inout [TokenChange], _ lookups: [Lookup]) {
            for (position, lookup) in lookups.enumerated() {
                let id = list[position].id
                switch lookup {
                case let .token(index): list[position].want = (eventsB[id]?[index] ?? eventsA[id]?[index])?.want ?? "?"
                case .whole: list[position].want = (eventsB[id]?.wholeCase ?? eventsA[id]?.wholeCase)?.want ?? "?"
                }
            }
        }
        fill(&broken, brokenLookups)
        fill(&fixed, fixedLookups)
        return DiffData(a: label(a), b: label(b), common: common, onlyA: distinctA - common,
                        onlyB: distinctB - common, rows: rows, broken: broken, fixed: fixed,
                        brokenTest: brokenTest, fixedTest: fixedTest, notes: notes)
    }

    private static func label(_ run: RunData) -> String { "\(run.info.system)@\(run.info.commit)" }
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
            out += "  \(change.id)" + (change.index.map { " #\($0)" } ?? "") + "  «\(visible(change.want))»  было \(change.before) → стало \(change.after)\n"
        }
        if changes.count > list { out += "  …и ещё \(changes.count - list)\n" }
        return out
    }

    /// A line break or tab in a word shows as its escape, so one change stays on one line.
    private static func visible(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
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
