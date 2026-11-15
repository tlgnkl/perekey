// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The files of a run in `<run dir>/` (docs/eval.md, «Файлы прогона»).
/// `cases.tsv` and `summary.json` depend on the cases, the model and the
/// code alone: two runs give the same bytes.
public enum RunFiles {
    /// What `run.json` records about the run.
    public struct Info: Hashable, Sendable, Codable {
        public var caseFormat = EvalCase.version
        public var scorer = Scorer.version
        public var commit: String
        /// SHA-256 of each model file, by language.
        public var models: [String: String]
        public var system: String
        /// The `--settings` preset over every case's own, if given.
        public var settings: String?
        /// The `--options` JSON, if given.
        public var options: String?
        public var files: [CaseFile]
        public var split: String
        public var only: [String]?
        /// The tier of built cases; nil for cases written by hand.
        public var tier: String?
        /// Whether words of the test part may be shown.
        public var testRevealed = false
        /// SHA-256 of each lexicon file by language, of the lists of `data/`, and of
        /// the files of decisions about the source's noise; nil without a lexicon.
        public var lexicon: [String: String]?
        public var seen: String?
        public var noise: [CaseFile]?
        /// The run holds a personal set: its files are in the private
        /// folder, and its words are hashes.
        public var personal: Bool?

        public struct CaseFile: Hashable, Sendable, Codable {
            public var path: String
            public var sha256: String
        }
    }

    /// One line per case: id, words of the measured part, the outcome letter
    /// of every token (the warm-up first), how many of them are the
    /// warm-up's, exact (1 or 0), lag (- when it does not apply), checks
    /// (`ok`, `failed`, - without checks).
    public static func casesTSV(_ scores: [CaseScore]) -> String {
        casesHeader + "\n" + scores.map { caseLine($0) + "\n" }.joined()
    }

    static let casesHeader = "id\twords\twarmup\toutcomes\texact\tlag\tchecks"

    static func caseLine(_ score: CaseScore) -> String {
        let outcomes = score.scoring == .case ? "-" : score.outcomeString
        return [score.id, String(score.words), String(score.warmupTokens), outcomes.isEmpty ? "-" : outcomes,
                score.exact ? "1" : "0", score.lag.map(String.init) ?? "-",
                score.checkCount == 0 ? "-" : score.failedChecks.isEmpty ? "ok" : "failed"]
            .joined(separator: "\t")
    }

    /// One line per case with the counts the report needs to resample cases and
    /// to compare two runs: id, suite, scenario, split, epoch, lag, then the
    /// counters of `countColumns` and the weighted ones.
    public static func countsTSV(_ scores: [CaseScore]) -> String {
        countsHeader + "\n" + scores.map { countsLine($0) + "\n" }.joined()
    }

    static let countsHeader = (["id", "suite", "scenario", "split", "epoch", "lag"] + countColumns.map(\.name)
        + weightedColumns.map(\.name)).joined(separator: "\t")

    static func countsLine(_ score: CaseScore) -> String {
        let metrics = Metrics(score)
        return (([score.id, score.suite, score.scenario, score.split.rawValue, String(score.epoch),
                  score.lag.map(String.init) ?? "-"])
            + countColumns.map { String(metrics[keyPath: $0.path]) }
            + weightedColumns.map { weightText(metrics[keyPath: $0.path]) }).joined(separator: "\t")
    }

    /// The integer counters of `counts.tsv`, in column order.
    static let countColumns: [(name: String, path: WritableKeyPath<Metrics, Int> & Sendable)] = [
        ("exact", \.exact), ("checksFailed", \.checksFailed), ("tokens", \.tokens), ("words", \.words),
        ("ok", \.ok), ("fixed", \.fixed), ("harm", \.harm), ("harmEvents", \.harmEvents), ("miss", \.miss),
        ("botched", \.botched), ("spill", \.spill), ("disputed", \.disputed), ("silent", \.silent),
        ("layoutErrors", \.layoutErrors), ("missLayout", \.missLayout), ("errors", \.errors),
        ("wrong", \.wrong), ("wrongNull", \.wrongNull),
    ]

    /// The weighted counters of `counts.tsv`.
    static let weightedColumns: [(name: String, path: WritableKeyPath<Metrics, Double> & Sendable)] = [
        ("weightedWords", \.weightedWords), ("weightedHarm", \.weightedHarm),
        ("weightedLayoutErrors", \.weightedLayoutErrors), ("weightedMissLayout", \.weightedMissLayout),
    ]

    static func weightText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.6f", value)
    }

    /// One line per word type of the measured part with a letter, by part: how
    /// many times it occurs, how often it was harmed, missed, botched, and the
    /// summed weight of those errors. The words of the test part only if the
    /// run reveals them (`--reveal-test`); the report hides them again without its own flag.
    /// The words of a personal set are hashes of the store's salt.
    public static func wordsTSV(_ scores: [CaseScore], redactor: Redactor? = nil) -> String {
        var words = Words(redactor: redactor)
        for score in scores { words.add(score) }
        return words.tsv()
    }

    /// The rows of `words.tsv`, counted one case at a time.
    struct Words {
        struct Key: Hashable, Comparable {
            var split: String
            var word: String
            static func < (a: Key, b: Key) -> Bool { (a.split, a.word) < (b.split, b.word) }
        }
        struct Row { var occurrences = 0, harm = 0, miss = 0, botched = 0, weight = 0.0 }
        var rows: [Key: Row] = [:]
        let redactor: Redactor?

        init(redactor: Redactor?) { self.redactor = redactor }

        mutating func add(_ score: CaseScore) {
            guard !score.hidden && (!score.personal || redactor != nil) else { return }
            for token in score.measured where Tokenizer.isWord(token.want) {
                let core = Lexicon.core(token.want)
                guard !core.isEmpty else { continue }
                // A personal word is its hash; without the salt it is left out above.
                let word = score.personal ? redactor?.hash(core) ?? Redactor.withheld : core
                let key = Key(split: score.split.rawValue, word: word)
                rows[key, default: Row()].occurrences += 1
                switch token.outcome {
                case .harm: rows[key]!.harm += 1; rows[key]!.weight += token.weight
                case .miss: rows[key]!.miss += 1; rows[key]!.weight += token.weight
                case .botched: rows[key]!.botched += 1; rows[key]!.weight += token.weight
                default: break
                }
            }
        }

        func tsv() -> String {
            var lines = ["split\tword\toccurrences\tharm\tmiss\tbotched\terrorWeight"]
            for key in rows.keys.sorted() {
                let row = rows[key]!
                lines.append([key.split, key.word, String(row.occurrences), String(row.harm), String(row.miss),
                              String(row.botched), RunFiles.weightText(row.weight)].joined(separator: "\t"))
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    public static func slicesJSON(_ scores: [CaseScore]) throws -> String {
        try pretty(SliceTable(scores))
    }

    /// What files say instead of a word of the hidden test part.
    public static let hiddenText = "(test)"

    /// One line per token that is not `ok`, one per case scored as a whole
    /// whose text differs, and one per case whose checks failed. Words of a
    /// hidden case read `(test)`; those of a personal case are hashes.
    public static func eventsJSONL(_ scores: [CaseScore], redactor: Redactor? = nil) throws -> String {
        try scores.map { try eventLines($0, redactor: redactor).map { $0 + "\n" }.joined() }.joined()
    }

    static func eventLines(_ score: CaseScore, redactor: Redactor?) throws -> [String] {
        var lines: [String] = []
        func shown(_ text: String) -> String {
            if score.personal { return redactor?.hash(text) ?? Redactor.withheld }
            return score.hidden ? hiddenText : text
        }
        let wholeCase = score.scoring == .case
        let textDiffers = wholeCase && !score.exact
        let hasFailedChecks = !score.failedChecks.isEmpty
        if wholeCase || hasFailedChecks {
            if textDiffers || hasFailedChecks {
                lines.append(try CaseCodec.json(CaseEvent(
                    id: score.id, outcome: score.exact ? "checks" : "fail", want: shown(score.wantText),
                    null: shown(score.nullText), out: shown(score.outText),
                    checks: score.failedChecks.isEmpty ? nil : score.failedChecks
                )))
            }
            if wholeCase { return lines }
        }
        for token in score.tokens where token.outcome != .ok {
            lines.append(try CaseCodec.json(TokenEvent(
                id: score.id, index: token.index, want: shown(token.want), null: shown(token.null),
                out: shown(token.out),
                outcome: token.outcome.rawValue, form: token.form, cascade: token.cascade ? true : nil,
                silent: token.silent ? true : nil,
                features: token.features, trace: token.trace.isEmpty ? nil : token.trace
            )))
        }
        return lines
    }

    static func summaryJSON(_ accumulated: Summary.Accumulator) throws -> String {
        try pretty(Summary(accumulated))
    }

    static func slicesJSON(_ accumulated: SliceTable.Accumulator) throws -> String {
        try pretty(SliceTable(accumulated))
    }

    public static func summaryJSON(_ scores: [CaseScore]) throws -> String {
        try pretty(Summary(scores))
    }

    public static func runJSON(_ info: Info) throws -> String {
        try pretty(info)
    }

    /// A run with a personal set is written for its owner alone (folder 0700,
    /// files 0600) and needs the `redactor` of the store: without it the
    /// words of the set would have no hash to stand for them.
    public static func write(_ scores: [CaseScore], info: Info, to directory: String, redactor: Redactor? = nil) throws {
        let writer = try Writer(to: directory, personal: scores.contains(where: \.personal), redactor: redactor)
        for score in scores { try writer.add(score) }
        try writer.finish(info: info)
    }

    /// Writes a run one case at a time: the lines of `cases.tsv`, `counts.tsv` and `events.jsonl` go to
    /// their files as the cases are scored, and the other files come from counts that grow with the
    /// cases, not from the cases. The bytes are those of `write`. A file replaces the old one when
    /// `finish` is called.
    public final class Writer {
        private let directory: String
        private let personal: Bool
        private let redactor: Redactor?
        private var cases: LineFile
        private var counts: LineFile
        private var events: LineFile
        private var summary = Summary.Accumulator()
        private var slices = SliceTable.Accumulator()
        private var words: Words

        /// `personal`: the run holds a personal set (it is known before the first case is played).
        public init(to directory: String, personal: Bool, redactor: Redactor? = nil) throws {
            guard !personal || redactor != nil else {
                throw EvalError.input("a run with a personal set needs \(PrivateStore.variable)")
            }
            self.directory = directory
            self.personal = personal
            self.redactor = redactor
            words = Words(redactor: redactor)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: personal ? [.posixPermissions: 0o700] : nil)
            if personal { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }
            cases = try LineFile(directory: directory, name: "cases.tsv", personal: personal)
            counts = try LineFile(directory: directory, name: "counts.tsv", personal: personal)
            events = try LineFile(directory: directory, name: "events.jsonl", personal: personal)
            try cases.append(RunFiles.casesHeader + "\n")
            try counts.append(RunFiles.countsHeader + "\n")
        }

        public func add(_ score: CaseScore) throws {
            var score = score
            // The id of a personal case is a hash of its content: files name it with the salted one.
            if personal, score.personal { score.id = redactor?.caseID(score.id) ?? score.id }
            try cases.append(RunFiles.caseLine(score) + "\n")
            try counts.append(RunFiles.countsLine(score) + "\n")
            for line in try RunFiles.eventLines(score, redactor: redactor) { try events.append(line + "\n") }
            summary.add(score)
            slices.add(score)
            words.add(score)
        }

        @discardableResult
        public func finish(info: Info) throws -> Summary {
            var info = info
            if personal { info.personal = true }
            try cases.close()
            try counts.close()
            try events.close()
            let result = Summary(summary)
            for (name, text) in try [
                ("run.json", RunFiles.runJSON(info)),
                ("summary.json", RunFiles.pretty(result)),
                ("slices.json", RunFiles.pretty(SliceTable(slices))),
                ("words.tsv", words.tsv()),
            ] {
                try LineFile.write(text, directory: directory, name: name, personal: personal)
            }
            return result
        }
    }

    /// A file written in pieces: the pieces go to a temporary file in the same folder, which takes the
    /// name of the file when the last piece is written.
    private struct LineFile {
        private let path: String
        private let temporary: String
        private let handle: FileHandle
        private var buffer = ""

        init(directory: String, name: String, personal: Bool) throws {
            path = (directory as NSString).appendingPathComponent(name)
            temporary = path + ".partial"
            guard FileManager.default.createFile(atPath: temporary, contents: nil,
                                                 attributes: personal ? [.posixPermissions: 0o600] : nil)
            else { throw EvalError.input("cannot write \(temporary)") }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temporary))
        }

        mutating func append(_ text: String) throws {
            buffer += text
            if buffer.utf8.count >= 1 << 20 { try flush() }
        }

        private mutating func flush() throws {
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer = ""
        }

        mutating func close() throws {
            try flush()
            try handle.close()
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: temporary, toPath: path)
        }

        static func write(_ text: String, directory: String, name: String, personal: Bool) throws {
            let path = (directory as NSString).appendingPathComponent(name)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            if personal { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        }
    }

    static func pretty(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
    }

    struct TokenEvent: Encodable {
        var id: String
        var index: Int
        var want: String
        var null: String
        var out: String
        var outcome: String
        var form: String?
        var cascade: Bool?
        var silent: Bool?
        var features: TokenFeatures?
        var trace: [TraceEntry]?
    }

    struct CaseEvent: Encodable {
        var id: String
        var outcome: String
        var want: String
        var null: String
        var out: String
        var checks: [Check]?
    }
}

/// The commit of the working directory, for run.json.
public enum GitCommit {
    public static func current() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "unknown"
        }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !text.isEmpty ? text : "unknown"
    }
}
