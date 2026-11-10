// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import PerekeyCore

/// What the scorer needs beyond the case and the two texts: the lexicon, the
/// lists of `data/`, and the decisions about the source's noise (docs/eval.md,
/// «Спорно и тихо»). Without it the scorer gives no `disputed`, no `silent`
/// and none of the features `known`, `zipf`, `collision`, `seen`.
public struct Knowledge: Sendable {
    /// The numbers of the rules, each with where it comes from.
    public struct Options: Sendable {
        /// The least Zipf of the system's word for a harm to be disputed: plan, 7.5.
        public var disputedMinZipf = 3.0
        /// The least Zipf of a word the keys give in another layout for a collision: plan, 7.6.
        public var collisionMinZipf = 3.0
        /// The edit distance (Damerau–Levenshtein, adjacent swaps count one) of a
        /// disputed harm: plan, 7.5.
        public var disputedDistance = 1
        /// Suites whose intended text is known exactly: no disputed outcome
        /// there (plan, 7.5). `class.*`, `protect.*`, `typos.*` and `flow.*` go by prefix.
        public var exactSuites: Set<String> = ["yo", "hyphen", "doublecap", "capslock", "abbrev", "incidents"]
        public var exactPrefixes = ["class.", "protect.", "typos.", "flow."]

        public init() {}
    }

    public var lexicon: Lexicon
    public var seen: SeenWords?
    public var noise: NoiseDecisions
    public var options = Options()

    public init(lexicon: Lexicon, seen: SeenWords? = nil, noise: NoiseDecisions = NoiseDecisions(),
                options: Options = Options())
    {
        self.lexicon = lexicon
        self.seen = seen
        self.noise = noise
        self.options = options
    }

    /// Whether the rule of disputed outcomes (plan, 7.5) holds in the suite:
    /// the corpus suites, where the source has typos of its own.
    public func disputes(suite: String) -> Bool {
        !options.exactSuites.contains(suite) && !options.exactPrefixes.contains { suite.hasPrefix($0) }
    }

    /// Plan, 7.5: the intended word is not in the lexicon, the system's word is
    /// there with Zipf from 3, and they differ by one edit (or by a hyphen or
    /// «ё» alone). The source's typo, mended by the system.
    public func isDisputed(want: String, out: String, language: String) -> Bool {
        guard lexicon.has(language: language), !out.contains(where: \.isWhitespace) else { return false }
        let wantCore = Lexicon.core(want), outCore = Lexicon.core(out)
        guard !wantCore.isEmpty, !outCore.isEmpty, wantCore != outCore,
              !lexicon.contains(wantCore, language: language),
              let zipf = lexicon.zipf(of: outCore, language: language), zipf >= options.disputedMinZipf
        else { return false }
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "ё", with: "е") }
        if plain(wantCore) == plain(outCore) { return true }
        return Self.distance(Array(plain(wantCore)), Array(plain(outCore))) <= options.disputedDistance
    }

    /// Plan, 7.3 («тихая»): the output is a word of the lexicon in a language
    /// of its script, among the languages of the case. The person does not notice it.
    public func isSilent(out: String, languages: [String]) -> Bool {
        guard !out.contains(where: \.isWhitespace) else { return false }
        let core = Lexicon.core(out)
        guard let script = Lexicon.script(of: core) else { return false }
        return languages.contains { Lexicon.scripts[$0] == script && lexicon.contains(core, language: $0) }
    }

    /// The Zipf range of a word by the lexicon (plan, 7.6).
    public func zipfBucket(_ token: String, language: String) -> String {
        guard language != "-", let zipf = lexicon.zipf(of: Lexicon.core(token), language: language) else { return "none" }
        return zipf < 2 ? "<2" : zipf < 3 ? "2-3" : zipf < 4 ? "3-4" : zipf < 5 ? "4-5" : "5+"
    }

    /// The optimal string alignment distance: insertions, deletions,
    /// substitutions and swaps of two neighbours, each one.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { rows[i][0] = i }
        for j in 0...b.count { rows[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                rows[i][j] = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
                }
            }
        }
        return rows[a.count][b.count]
    }
}

/// The decisions about the noise of a source (plan, 7.5): `eval/noise/<suite>.tsv`.
///
/// One line per token: the case `id`, the token's number among the tokens of
/// `want` (the same as `index` in `events.jsonl`), the decision `source-typo`
/// or `harm`, and for `source-typo` the form to accept. Lines starting with `#`
/// are comments. A decision for a case of the `test` part is ignored: the part
/// has no file of decisions, only the rule.
public struct NoiseDecisions: Sendable {
    public enum Decision: Hashable, Sendable {
        /// The source has a typo here: the form joins `accept`.
        case sourceTypo(form: String)
        /// A harm after all: the rule of disputed outcomes does not apply.
        case harm
    }

    private var byCase: [String: [Int: Decision]] = [:]
    /// The files read, with SHA-256 of their bytes, for run.json.
    public private(set) var files: [RunFiles.Info.CaseFile] = []

    public init() {}

    public init(decisions: [String: [Int: Decision]]) {
        byCase = decisions
    }

    /// Every `.tsv` file of the directory, in name order; a missing directory has none.
    public init(directory: String) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names.filter({ $0.hasSuffix(".tsv") }).sorted() {
            let path = (directory as NSString).appendingPathComponent(name)
            try add(String(contentsOfFile: path, encoding: .utf8), file: path)
            files.append(.init(path: path, sha256: try Runner.sha256(file: path)))
        }
    }

    public mutating func add(_ text: String, file: String = "noise") throws {
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            func fail(_ reason: String) -> EvalError { .input("\(file):\(number + 1): \(reason)") }
            guard fields.count >= 3, let index = Int(fields[1]), index >= 0 else {
                throw fail("expected: case id, token number, source-typo|harm[, accepted form]")
            }
            switch fields[2] {
            case "harm":
                byCase[fields[0], default: [:]][index] = .harm
            case "source-typo":
                guard fields.count >= 4, !fields[3].isEmpty else { throw fail("source-typo needs the accepted form") }
                byCase[fields[0], default: [:]][index] = .sourceTypo(form: fields[3])
            default:
                throw fail("unknown decision \(fields[2]): source-typo or harm")
            }
        }
    }

    public func decisions(for item: EvalCase) -> [Int: Decision] {
        item.split == .dev ? byCase[item.id] ?? [:] : [:]
    }
}
