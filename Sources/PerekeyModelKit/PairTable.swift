// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The pairs of neighbouring words of a training text with their counts, and
/// what the model keeps of them (docs/classifier.md, «Пары слов»).
///
/// `PairTable.count` reads the text of `scripts/wiki-text.py` and writes
/// `<cache>/pairs/<language>.tsv`; `ModelBuild` reads that file and passes the
/// best pairs to `ModelBuilder.addPair`. The two steps are apart because
/// counting takes minutes and the model builds in seconds.
public struct PairTable: Sendable {
    /// The numbers of this lane. Each one says where it comes from and what
    /// to run to check it.
    public struct Options: Sendable {
        /// A pair seen fewer times is chance, not evidence. Plan 8.1, point 4.
        /// Check: `perekey-eval pairs` prints the share of held-out pairs found for 2, 3, 4.
        public var minCount = 3
        /// The least lift a pair keeps, in eighths of a bit: one bit. Plan 8.1,
        /// point 4. Check: as `minCount`.
        public var minLift = 8
        /// Absolute discounting, the usual value for text of this size
        /// (Ney, Essen, Kneser 1994: `D = n₁ / (n₁ + 2·n₂)`, here about
        /// 0.75). Plan 8.1, point 4.
        public var discount = 0.75
        /// The pass-1 sketch has `2^sketchBits` one-byte counters: pairs that
        /// cannot reach `minCount` are not counted in pass 2. 2²⁷ is 128 MB,
        /// the sketch alone; the peak of the whole run is about 0.8 GB (the
        /// sketch, the dictionaries, the exact counts of pass 2). A smaller
        /// sketch lets more rare pairs through and costs memory in pass 2,
        /// never changes the result. Check: `/usr/bin/time -l perekey-model
        /// pairs`, "maximum resident set size".
        public var sketchBits = 27
        /// The largest "pair" section in bytes. Decision Р4 of the plan.
        public var budget = ModelFormat.pairBudget

        public init() {}
    }

    public struct Entry: Equatable, Sendable {
        public var previous: UInt64
        public var word: UInt64
        public var count: Int
        /// How often `previous` has a word after it in the text.
        public var previousTotal: Int
        /// How often `word` occurs after any word, the start of a sentence included.
        public var wordTotal: Int
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The format of the file; a change of how pairs are counted raises it.
    public static let formatVersion = 1

    public var language: String
    /// Words of the text, known or not: the denominator of `P(word)`.
    public var tokens: Int
    /// What the dictionary held when the pairs were counted: the number of
    /// known forms and their checksum. A file counted against another
    /// dictionary is stale (`known(_:)`).
    public var known: String
    /// The training files, as their lines in `MANIFEST.sha256`.
    public var sources: [String]
    /// Sorted by `previous`, then `word`.
    public var entries: [Entry]

    public init(language: String, tokens: Int, known: String, sources: [String], entries: [Entry]) {
        self.language = language
        self.tokens = tokens
        self.known = known
        self.sources = sources
        self.entries = entries
    }

    /// The description of a set of known forms: how many, and FNV-1a 64 of
    /// their sorted fingerprints.
    public static func known(_ forms: [UInt64]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for form in forms {
            var value = form
            for _ in 0..<8 {
                hash ^= value & 0xFF
                hash = hash &* 0x0000_0100_0000_01B3
                value >>= 8
            }
        }
        return "\(forms.count):\(String(hash, radix: 16))"
    }

    // MARK: Counting

    /// Counts the pairs of a text and keeps those worth a table.
    ///
    /// Two passes over the text. Pass 1 counts the words, and the pairs in a
    /// sketch of saturating counters. Pass 2 counts exactly the pairs whose
    /// counter reached `minCount`: every pair that occurs `minCount` times is
    /// there, with some strangers that share a counter and fall out at the
    /// end. The peak memory is the sketch plus the pairs of pass 2, not all
    /// the pairs of the text.
    ///
    /// - Parameters:
    ///   - source: calls its argument with every line of the text (an
    ///     article, or a part of one), in the same order each time.
    ///   - knownForms: the folded fingerprints of the forms the model counts
    ///     as words of its language (`ModelBuilder.knownForms`). Pairs hold
    ///     known words only; the rest are counted as words and as neighbours.
    public static func count(language: String, sources: [String], knownForms: [UInt64], options: Options = Options(),
                             source: (_ line: (UnsafeRawBufferPointer) -> Void) throws -> Void) throws -> PairTable
    {
        let known = Set(knownForms)
        let sketchShift = UInt64(64 - options.sketchBits)
        var sketch = [UInt8](repeating: 0, count: 1 << options.sketchBits)
        var following: [UInt64: Int] = [:] // how often a word has a word after it
        var occurring: [UInt64: Int] = [:] // how often a word occurs
        var tokens = 0

        func slot(_ key: UInt64) -> Int { Int(key >> sketchShift) }

        // The pairs of a line, each as (previous, word) with the unknown as nil.
        func pairs(_ line: UnsafeRawBufferPointer, _ body: (_ previous: UInt64?, _ word: UInt64?) -> Void) {
            var previous: UInt64? = ModelFormat.sentenceStart
            PairText.scan(line) { event in
                switch event {
                case .word(let fingerprint):
                    let word = known.contains(fingerprint) ? fingerprint : nil
                    body(previous, word)
                    previous = word
                case .sentenceEnd:
                    previous = ModelFormat.sentenceStart
                }
            }
        }

        try source { line in
            pairs(line) { previous, word in
                tokens += 1
                if let previous { following[previous, default: 0] += 1 }
                if let word { occurring[word, default: 0] += 1 }
                if let previous, let word {
                    let index = slot(ModelFormat.pairKey(previous: previous, word: word))
                    if sketch[index] < 255 { sketch[index] += 1 }
                }
            }
        }

        struct Key: Hashable {
            var previous: UInt64
            var word: UInt64
        }
        var exact: [Key: Int] = [:]
        let enough = UInt8(min(options.minCount, 255))
        try source { line in
            pairs(line) { previous, word in
                guard let previous, let word,
                      sketch[slot(ModelFormat.pairKey(previous: previous, word: word))] >= enough
                else { return }
                exact[Key(previous: previous, word: word), default: 0] += 1
            }
        }
        sketch = []

        var entries: [Entry] = []
        for (key, count) in exact where count >= options.minCount {
            guard let previousTotal = following[key.previous], let wordTotal = occurring[key.word],
                  let lift = ModelBuilder.pairLift(count: count, previous: previousTotal, word: wordTotal,
                                                   total: tokens, discount: options.discount),
                  lift >= options.minLift
            else { continue }
            entries.append(Entry(previous: key.previous, word: key.word, count: count, previousTotal: previousTotal,
                                 wordTotal: wordTotal))
        }
        entries.sort { ($0.previous, $0.word) < ($1.previous, $1.word) }
        return PairTable(language: language, tokens: tokens, known: Self.known(knownForms.sorted()),
                         sources: sources, entries: entries)
    }

    // MARK: The file

    /// `# key value` lines, then `previous word count previous-total word-total`
    /// per pair, the fingerprints in 16 hex digits, tab-separated. Sorted:
    /// two runs on one text write one file. Only numbers: no word is in it.
    public func tsv() -> String {
        var text = "# perekey pairs \(Self.formatVersion)\n# language \(language)\n# tokens \(tokens)\n"
        text += "# known \(known)\n"
        // The count of the lines below: a file cut at a line end is still whole lines.
        text += "# entries \(entries.count)\n"
        for source in sources { text += "# source \(source)\n" }
        text.reserveCapacity(text.utf8.count + entries.count * 60)
        for entry in entries {
            text += Self.hex(entry.previous) + "\t" + Self.hex(entry.word) + "\t\(entry.count)\t\(entry.previousTotal)\t\(entry.wordTotal)\n"
        }
        return text
    }

    /// Writes `tsv()` to `path`: first to `path.part`, then in place of `path`
    /// in one step, so a stopped run leaves the old file or none, never half.
    /// The target may be missing (the first run in a cache).
    public func write(to path: String) throws {
        let fileManager = FileManager.default
        let part = path + ".part"
        try tsv().write(toFile: part, atomically: false, encoding: .utf8)
        do {
            if fileManager.fileExists(atPath: path) {
                _ = try fileManager.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: part))
            } else {
                try fileManager.moveItem(atPath: part, toPath: path)
            }
        } catch {
            try? fileManager.removeItem(atPath: part)
            throw error
        }
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    public static func read(_ path: String) throws -> PairTable {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var language = "", known = ""
        var tokens = -1, version = -1, declared = -1
        var sources: [String] = []
        var entries: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") {
                let fields = line.dropFirst(2).split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { continue }
                let value = String(fields[1])
                switch fields[0] {
                case "perekey": version = Int(value.dropFirst("pairs ".count)) ?? -1
                case "language": language = value
                case "tokens": tokens = Int(value) ?? -1
                case "known": known = value
                case "entries": declared = Int(value) ?? -1
                case "source": sources.append(value)
                default: break
                }
                continue
            }
            let fields = line.split(separator: "\t")
            guard fields.count == 5, let previous = UInt64(fields[0], radix: 16), let word = UInt64(fields[1], radix: 16),
                  let count = Int(fields[2]), let previousTotal = Int(fields[3]), let wordTotal = Int(fields[4])
            else { throw Failure(description: "\(path): bad line: \(line)") }
            entries.append(Entry(previous: previous, word: word, count: count, previousTotal: previousTotal,
                                 wordTotal: wordTotal))
        }
        guard version == formatVersion, tokens > 0, !language.isEmpty, !known.isEmpty else {
            throw Failure(description: "\(path): not a pairs file of this version (run scripts/build-pairs.sh)")
        }
        guard declared == entries.count else {
            throw Failure(description: "\(path): the file says \(declared) pairs and holds \(entries.count): cut or damaged (run scripts/build-pairs.sh)")
        }
        return PairTable(language: language, tokens: tokens, known: known, sources: sources, entries: entries)
    }

    // MARK: Selection

    /// A pair for the model: its lift in eighths of a bit, at most 255.
    public struct Chosen: Equatable, Sendable {
        public var entry: Entry
        public var lift: UInt8
    }

    /// The pairs the model keeps: every pair with at least `minCount` and
    /// `minLift`, and if the section would pass `budget`, the best by
    /// `lift · log₂(count)` that fit. Sorted by `previous`, `word`.
    public func chosen(_ options: Options = Options(), budget: Int? = nil) -> [Chosen] {
        var candidates: [(chosen: Chosen, score: Double)] = []
        candidates.reserveCapacity(entries.count)
        for entry in entries where entry.count >= options.minCount {
            guard let lift = ModelBuilder.pairLift(count: entry.count, previous: entry.previousTotal,
                                                   word: entry.wordTotal, total: tokens, discount: options.discount),
                  lift >= options.minLift
            else { continue }
            let stored = UInt8(min(lift, 255))
            candidates.append((Chosen(entry: entry, lift: stored), ModelBuilder.pairScore(lift: stored, count: entry.count)))
        }
        let limit = budget ?? options.budget
        if ModelBuilder.pairSectionSize(count: candidates.count) > limit {
            // The most entries whose section fits; the size never falls as the count grows.
            var low = 0, high = candidates.count
            while low < high {
                let middle = (low + high + 1) / 2
                if ModelBuilder.pairSectionSize(count: middle) <= limit { low = middle } else { high = middle - 1 }
            }
            candidates.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return ($0.chosen.entry.previous, $0.chosen.entry.word) < ($1.chosen.entry.previous, $1.chosen.entry.word)
            }
            candidates = Array(candidates.prefix(low))
            candidates.sort { ($0.chosen.entry.previous, $0.chosen.entry.word) < ($1.chosen.entry.previous, $1.chosen.entry.word) }
        }
        return candidates.map(\.chosen)
    }
}

/// Reads a text file line by line from the disk in blocks, so a file of
/// 400 MB is never in memory whole. A last line without a line end counts.
public enum TextLines {
    public static func forEach(path: String, _ body: (UnsafeRawBufferPointer) -> Void) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw PairTable.Failure(description: "cannot open \(path)")
        }
        defer { try? handle.close() }
        var rest = Data()
        while true {
            let block = try autoreleasepool(invoking: { try handle.read(upToCount: 4 << 20) }) ?? Data()
            if block.isEmpty { break }
            rest.append(block)
            var start = rest.startIndex
            rest.withUnsafeBytes { bytes in
                var from = 0
                while let end = bytes[from...].firstIndex(of: 0x0A) {
                    body(UnsafeRawBufferPointer(rebasing: bytes[from..<end]))
                    from = end + 1
                }
                start = rest.startIndex + from
            }
            rest = Data(rest[start...])
        }
        if !rest.isEmpty { rest.withUnsafeBytes(body) }
    }
}
