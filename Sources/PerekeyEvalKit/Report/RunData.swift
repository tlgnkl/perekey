// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A run read back from its directory: what `report` and `diff` work from.
/// They read files, not the cases, so they need neither the model nor the layouts.
public struct RunData: Sendable {
    /// A row of `counts.tsv`: a case and its counts.
    public struct Row: Sendable {
        public var id: String
        public var suite: String
        public var scenario: String
        public var split: String
        public var epoch: Int
        public var lag: Int?
        public var metrics: Metrics
    }

    /// A line of `events.jsonl`: a token that is not `ok`, or a case that failed.
    public struct Event: Sendable, Decodable {
        public var id: String
        public var index: Int?
        public var want: String
        public var null: String
        public var out: String
        public var outcome: String
        public var form: String?
        public var silent: Bool?
        public var features: TokenFeatures?
    }

    /// A line of `words.tsv`.
    public struct Word: Sendable {
        public var split: String
        public var word: String
        public var occurrences: Int
        public var harm: Int
        public var miss: Int
        public var botched: Int
        public var errorWeight: Double
    }

    /// The part of `summary.json` the report reads.
    struct SummaryHead: Decodable {
        var schema: Int
        var scorer: Int
        var incidents: Summary.Incidents
    }

    public var directory: String
    public var info: RunFiles.Info
    public var scorer: Int
    public var incidents: Summary.Incidents
    public var rows: [Row]
    /// Case id → outcome letters of its tokens, the warm-up first, and how many are the warm-up's.
    public var outcomes: [String: (letters: String, warmup: Int)]
    public var events: [Event]
    public var slices: SliceTable
    public var words: [Word]

    public var splitOf: [String: String] { Dictionary(rows.map { ($0.id, $0.split) }, uniquingKeysWith: { first, _ in first }) }

    public static func load(_ directory: String) throws -> RunData {
        func text(_ name: String) throws -> String {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw EvalError.input("\(directory): no \(name); play the cases again with this version of perekey-eval")
            }
            return text
        }
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            do { return try decoder.decode(type, from: Data(text(name).utf8)) } catch let error as EvalError {
                throw error
            } catch {
                throw EvalError.input("\(directory)/\(name): \(error)")
            }
        }
        let info = try decode(RunFiles.Info.self, "run.json")
        let head = try decode(SummaryHead.self, "summary.json")
        guard head.schema == Summary.schema, head.scorer == Scorer.version else {
            throw EvalError.input("\(directory): written with summary schema \(head.schema), scorer \(head.scorer); "
                + "this is schema \(Summary.schema), scorer \(Scorer.version): play the cases again")
        }
        let slices = try decode(SliceTable.self, "slices.json")
        guard slices.schema == SliceTable.schema else { throw EvalError.input("\(directory)/slices.json: schema \(slices.schema)") }

        let rows = try parseCounts(text("counts.tsv"), file: "\(directory)/counts.tsv")
        var outcomes: [String: (String, Int)] = [:]
        for line in try text("cases.tsv").split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4, let warmup = Int(fields[2]) else { throw EvalError.input("\(directory)/cases.tsv: bad line") }
            outcomes[String(fields[0])] = (fields[3] == "-" ? "" : String(fields[3]), warmup)
        }
        var events: [Event] = []
        for line in try text("events.jsonl").split(separator: "\n") {
            do { events.append(try decoder.decode(Event.self, from: Data(line.utf8))) } catch {
                throw EvalError.input("\(directory)/events.jsonl: \(error)")
            }
        }
        var words: [Word] = []
        for line in try text("words.tsv").split(separator: "\n").dropFirst() {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, let occurrences = Int(f[2]), let harm = Int(f[3]), let miss = Int(f[4]),
                  let botched = Int(f[5]), let weight = Double(f[6])
            else { throw EvalError.input("\(directory)/words.tsv: bad line") }
            words.append(Word(split: f[0], word: f[1], occurrences: occurrences, harm: harm, miss: miss,
                              botched: botched, errorWeight: weight))
        }
        return RunData(directory: directory, info: info, scorer: head.scorer, incidents: head.incidents, rows: rows,
                       outcomes: outcomes, events: events, slices: slices, words: words)
    }

    static func parseCounts(_ text: String, file: String) throws -> [Row] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first?.split(separator: "\t").map(String.init) else { return [] }
        let head = ["id", "suite", "scenario", "split", "epoch", "lag"]
        let expected = head + RunFiles.countColumns.map(\.name) + RunFiles.weightedColumns.map(\.name)
        guard header == expected else { throw EvalError.input("\(file): the columns are not those of this version") }
        var rows: [Row] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == expected.count, let epoch = Int(f[4]) else { throw EvalError.input("\(file): bad line") }
            var metrics = Metrics()
            metrics.cases = 1
            var column = head.count
            for (name, path) in RunFiles.countColumns {
                guard let value = Int(f[column]) else { throw EvalError.input("\(file): bad \(name) in \(f[0])") }
                metrics[keyPath: path] = value
                column += 1
            }
            for (name, path) in RunFiles.weightedColumns {
                guard let value = Double(f[column]) else { throw EvalError.input("\(file): bad \(name) in \(f[0])") }
                metrics[keyPath: path] = value
                column += 1
            }
            metrics.fail = metrics.exact == 1 ? 0 : 1
            rows.append(Row(id: f[0], suite: f[1], scenario: f[2], split: f[3], epoch: epoch, lag: Int(f[5]),
                            metrics: metrics))
        }
        return rows
    }
}
