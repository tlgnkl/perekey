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
        var lines = ["id\twords\twarmup\toutcomes\texact\tlag\tchecks"]
        for score in scores {
            let outcomes = score.scoring == .case ? "-" : score.outcomeString
            lines.append([score.id, String(score.words), String(score.warmupTokens), outcomes.isEmpty ? "-" : outcomes,
                          score.exact ? "1" : "0", score.lag.map(String.init) ?? "-",
                          score.checkCount == 0 ? "-" : score.failedChecks.isEmpty ? "ok" : "failed"]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What files say instead of a word of the hidden test part.
    public static let hiddenText = "(test)"

    /// One line per token that is not `ok`, one per case scored as a whole
    /// whose text differs, and one per case whose checks failed. Words of a
    /// hidden case read `(test)`.
    public static func eventsJSONL(_ scores: [CaseScore]) throws -> String {
        var lines: [String] = []
        for score in scores {
            func shown(_ text: String) -> String { score.hidden ? hiddenText : text }
            if score.scoring == .case || !score.failedChecks.isEmpty {
                if !score.exact && score.scoring == .case || !score.failedChecks.isEmpty {
                    lines.append(try CaseCodec.json(CaseEvent(
                        id: score.id, outcome: score.exact ? "checks" : "fail", want: shown(score.wantText),
                        null: shown(score.nullText), out: shown(score.outText),
                        checks: score.failedChecks.isEmpty ? nil : score.failedChecks
                    )))
                }
                if score.scoring == .case { continue }
            }
            for token in score.tokens where token.outcome != .ok {
                lines.append(try CaseCodec.json(TokenEvent(
                    id: score.id, index: token.index, want: shown(token.want), null: shown(token.null),
                    out: shown(token.out),
                    outcome: token.outcome.rawValue, form: token.form, cascade: token.cascade ? true : nil,
                    features: token.features, trace: token.trace.isEmpty ? nil : token.trace
                )))
            }
        }
        return lines.map { $0 + "\n" }.joined()
    }

    public static func summaryJSON(_ scores: [CaseScore]) throws -> String {
        try pretty(Summary(scores))
    }

    public static func runJSON(_ info: Info) throws -> String {
        try pretty(info)
    }

    public static func write(_ scores: [CaseScore], info: Info, to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let files = try [
            ("run.json", runJSON(info)),
            ("cases.tsv", casesTSV(scores)),
            ("events.jsonl", eventsJSONL(scores)),
            ("summary.json", summaryJSON(scores)),
        ]
        for (name, text) in files {
            try text.write(toFile: (directory as NSString).appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
        }
    }

    private static func pretty(_ value: some Encodable) throws -> String {
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
