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
    public var rows: RowTable
    /// The outcome letters of the tokens of each case (the warm-up's first), by the position of the case in `rows`.
    /// Empty if the run was read without them (`Parts.outcomes`).
    public var outcomeLetters: [String]
    public var slices: SliceTable
    public var words: [Word]
    /// `events.jsonl` is not kept in memory (it is gigabytes on a full run): `events(of:)` reads it as a stream.
    var withholdDetails: Bool

    init(directory: String, info: RunFiles.Info, scorer: Int, incidents: Summary.Incidents, rows: RowTable,
         outcomeLetters: [String], slices: SliceTable, words: [Word], withholdDetails: Bool = false)
    {
        self.directory = directory
        self.info = info
        self.scorer = scorer
        self.incidents = incidents
        self.rows = rows
        self.outcomeLetters = outcomeLetters
        self.slices = slices
        self.words = words
        self.withholdDetails = withholdDetails
    }

    public var splitOf: [String: String] {
        var result: [String: String] = [:]
        for index in rows.indices where result[rows.id(at: index)] == nil { result[rows.id(at: index)] = rows.split(at: index) }
        return result
    }

    /// What `load` reads besides the small files. Everything a consumer does not name stays unread.
    public struct Parts: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// `cases.tsv`: the outcome letters of the tokens.
        public static let outcomes = Parts(rawValue: 1)
        /// `words.tsv`.
        public static let words = Parts(rawValue: 2)
        public static let all: Parts = [.outcomes, .words]
    }

    /// `withholdDetails`: the folder holds a personal run, so an error that comes from a file names only its type.
    /// `columns` and `parts` say what to read of the big files: the files are read as streams, and the run keeps only that.
    public static func load(_ directory: String, withholdDetails: Bool = false, columns: RowTable.Columns = .all,
                            parts: Parts = .all) throws -> RunData
    {
        func said(_ error: Error) -> String { withholdDetails ? "cannot be read (\(type(of: error)))" : "\(error)" }
        func missing(_ name: String) -> EvalError {
            EvalError.input("\(directory): no \(name); play the cases again with this version of perekey-eval")
        }
        func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }
        func text(_ name: String) throws -> String {
            guard let text = try? String(contentsOfFile: path(name), encoding: .utf8) else { throw missing(name) }
            return text
        }
        /// A file read as lines; a file that is missing or is not UTF-8 is the same error as before.
        func lines(_ name: String, _ body: (_ line: String) throws -> Void) throws {
            do {
                try RunLines.forEach(path: path(name)) { bytes in
                    guard let line = String(bytes: bytes, encoding: .utf8) else { throw RunLines.Unreadable() }
                    try body(line)
                }
            } catch is RunLines.Unreadable { throw missing(name) }
        }
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            do { return try decoder.decode(type, from: Data(text(name).utf8)) } catch let error as EvalError {
                throw error
            } catch {
                throw EvalError.input("\(directory)/\(name): \(said(error))")
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

        var builder = RowTable.Builder(columns: columns, file: "\(directory)/counts.tsv")
        try lines("counts.tsv") { try builder.add($0) }
        let rows = try builder.finish()

        var letters: [String] = []
        if parts.contains(.outcomes) {
            letters = Array(repeating: "", count: rows.count)
            var header = true
            var cursor = 0
            // The cases come in the order of the counts. If a line is not the next row's, the rows are looked up by id.
            var lastRow: [String: Int]?
            try lines("cases.tsv") { line in
                guard !line.isEmpty else { return }
                if header { header = false; return }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 4, let warmup = Int(fields[2]) else { throw EvalError.input("\(directory)/cases.tsv: bad line") }
                _ = warmup
                let outcome = fields[3] == "-" ? "" : String(fields[3])
                if lastRow == nil {
                    if cursor < rows.count, rows.id(at: cursor) == fields[0] {
                        letters[cursor] = outcome
                        cursor += 1
                        return
                    }
                    lastRow = [:]
                    for index in rows.indices { lastRow![rows.id(at: index)] = index }
                }
                // A case that is in no row has no counts: nothing reads it.
                if let row = lastRow![String(fields[0])] { letters[row] = outcome }
            }
        } else if !FileManager.default.fileExists(atPath: path("cases.tsv")) {
            throw missing("cases.tsv")
        }
        if !FileManager.default.fileExists(atPath: path("events.jsonl")) { throw missing("events.jsonl") }
        var words: [Word] = []
        if parts.contains(.words) {
            var header = true
            try lines("words.tsv") { line in
                guard !line.isEmpty else { return }
                if header { header = false; return }
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count == 7, let occurrences = Int(f[2]), let harm = Int(f[3]), let miss = Int(f[4]),
                      let botched = Int(f[5]), let weight = Double(f[6])
                else { throw EvalError.input("\(directory)/words.tsv: bad line") }
                words.append(Word(split: f[0], word: f[1], occurrences: occurrences, harm: harm, miss: miss,
                                  botched: botched, errorWeight: weight))
            }
        } else if !FileManager.default.fileExists(atPath: path("words.tsv")) {
            throw missing("words.tsv")
        }
        return RunData(directory: directory, info: info, scorer: head.scorer, incidents: head.incidents, rows: rows,
                       outcomeLetters: letters, slices: slices, words: words, withholdDetails: withholdDetails)
    }

    /// The events of the given cases, by case, then by token number (a case scored as a whole: position 0). The file
    /// is read as a stream and only the lines of these cases are decoded: a line has its `id` after the features, and
    /// the bytes of the id are compared before the JSON is read. A line without a plain `"id":"` is decoded whole.
    func events(of ids: Set<String>) throws -> [String: [Int: Event]] {
        var result: [String: [Int: Event]] = [:]
        guard !ids.isEmpty else { return result }
        let decoder = JSONDecoder()
        let needle = Array("\"id\":\"".utf8)
        let file = (directory as NSString).appendingPathComponent("events.jsonl")
        do {
            try RunLines.forEach(path: file) { line in
                if let value = Self.idBytes(in: line, after: needle), !value.contains(0x5C),
                   !ids.contains(String(decoding: value, as: UTF8.self)) { return }
                do {
                    let event = try decoder.decode(Event.self, from: Data(line))
                    if ids.contains(event.id) { result[event.id, default: [:]][event.index ?? 0] = event }
                } catch {
                    let said = withholdDetails ? "cannot be read (\(type(of: error)))" : "\(error)"
                    throw EvalError.input("\(directory)/events.jsonl: \(said)")
                }
            }
        } catch is RunLines.Unreadable {
            throw EvalError.input("\(directory): no events.jsonl; play the cases again with this version of perekey-eval")
        }
        return result
    }

    /// The bytes between `"id":"` and the next quote.
    private static func idBytes(in line: UnsafeBufferPointer<UInt8>, after needle: [UInt8]) -> UnsafeBufferPointer<UInt8>? {
        guard let base = line.baseAddress, line.count > needle.count,
              let found = memmem(base, line.count, needle, needle.count)
        else { return nil }
        let start = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + needle.count
        guard let end = memchr(base + start, 0x22, line.count - start) else { return nil }
        let stop = base.distance(to: end.assumingMemoryBound(to: UInt8.self))
        return UnsafeBufferPointer(start: base + start, count: stop - start)
    }
}

/// A file read as lines of bytes, in pieces: nothing keeps more than a piece and the line in hand.
enum RunLines {
    struct Unreadable: Error {}

    /// Calls `body` for each line without its `\n`, empty lines too; a last line with no `\n` is a line.
    /// A file that cannot be opened is `Unreadable`.
    static func forEach(path: String, _ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Unreadable() }
        defer { try? handle.close() }
        var pending: [UInt8] = []
        var more = true
        // A pool for each piece: the buffers `read` hands out are autoreleased, and a loop over a big file never drains them.
        while more {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty else { more = false; return }
                pending.append(contentsOf: chunk)
                var consumed = 0
                try pending.withUnsafeBufferPointer { bytes in
                    let base = bytes.baseAddress!
                    while consumed < bytes.count, let found = memchr(base + consumed, 0x0A, bytes.count - consumed) {
                        let end = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
                        try body(UnsafeBufferPointer(start: base + consumed, count: end - consumed))
                        consumed = end + 1
                    }
                }
                pending.removeSubrange(0 ..< consumed)
            }
        }
        if !pending.isEmpty { try pending.withUnsafeBufferPointer { try body($0) } }
    }
}

/// The rows of `counts.tsv`, kept as columns: a full run has millions of cases, and a `Row` with its `Metrics` is
/// hundreds of bytes. A row is made when it is asked for; a consumer that needs one counter reads that column.
public struct RowTable: RandomAccessCollection, Sendable {
    /// The counters to read. A bar reads a few of them; a report reads all.
    public enum Columns {
        case all
        /// Only these counters (the weighted ones and the rest read as 0); `fail` reads from `exact`.
        case only([KeyPath<Metrics, Int>])
    }

    private var ids: [String] = []
    /// The suites, scenarios and splits of the rows, each name once.
    private var names: [String] = []
    private var suites: [UInt32] = []
    private var scenarios: [UInt32] = []
    private var splits: [UInt32] = []
    private var epochs: [Int32] = []
    private var lags: [Int32] = []
    /// Which of `RunFiles.countColumns` are kept, and their values, row after row.
    private var loaded: [Int] = []
    private var counts: [Int32] = []
    private var weightedLoaded = false
    private var weighted: [Double] = []
    private static let noLag = Int32.min

    public init() {}

    /// A table of ready rows (the tests'). The counters of `cases` and `fail` are made from `exact` as always.
    public init(_ rows: [RunData.Row]) {
        var builder = Builder(columns: .all, file: "")
        for row in rows { builder.append(row) }
        self = builder.table
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { ids.count }

    public subscript(position: Int) -> RunData.Row {
        var metrics = Metrics()
        metrics.cases = 1
        let width = loaded.count
        for (slot, column) in loaded.enumerated() {
            metrics[keyPath: RunFiles.countColumns[column].path] = Int(counts[position * width + slot])
        }
        if weightedLoaded {
            for (slot, column) in RunFiles.weightedColumns.enumerated() {
                metrics[keyPath: column.path] = weighted[position * RunFiles.weightedColumns.count + slot]
            }
        }
        metrics.fail = metrics.exact == 1 ? 0 : 1
        return RunData.Row(id: ids[position], suite: names[Int(suites[position])], scenario: names[Int(scenarios[position])],
                           split: names[Int(splits[position])], epoch: Int(epochs[position]),
                           lag: lags[position] == Self.noLag ? nil : Int(lags[position]), metrics: metrics)
    }

    public func id(at position: Int) -> String { ids[position] }
    public func suite(at position: Int) -> String { names[Int(suites[position])] }
    public func split(at position: Int) -> String { names[Int(splits[position])] }
    /// The suite's number in `suiteNames`: rows of one suite have one number.
    func suiteNumber(at position: Int) -> Int { Int(suites[position]) }
    /// The names a suite number can have; the number is an index into it.
    var suiteNames: [String] { names }

    /// The positions of the rows by id, equal ids by position: the first of a group of equal ids is the row the id means.
    func orderedByID() -> [Int32] {
        var order = (0 ..< ids.count).map { Int32($0) }
        let ids = ids
        order.sort { left, right in
            let (x, y) = (ids[Int(left)], ids[Int(right)])
            return x == y ? left < right : x < y
        }
        return order
    }

    /// Every suite of the rows once, sorted.
    var distinctSuites: [String] { Set(suites.map { names[Int($0)] }).sorted() }

    /// The counter as a function of the row's position. A counter that was not read is 0.
    func counter(_ path: KeyPath<Metrics, Int>) -> (Int) -> Int {
        let width = loaded.count
        func slot(_ path: KeyPath<Metrics, Int>) -> Int? {
            RunFiles.countColumns.firstIndex { ($0.path as AnyKeyPath) == (path as AnyKeyPath) }.flatMap { loaded.firstIndex(of: $0) }
        }
        let counts = counts
        if (path as AnyKeyPath) == (\Metrics.cases as AnyKeyPath) { return { _ in 1 } }
        if (path as AnyKeyPath) == (\Metrics.fail as AnyKeyPath) {
            guard let exact = slot(\.exact) else { return { _ in 0 } }
            return { counts[$0 * width + exact] == 1 ? 0 : 1 }
        }
        guard let slot = slot(path) else { return { _ in 0 } }
        return { Int(counts[$0 * width + slot]) }
    }

    /// Reads the lines of `counts.tsv` one by one.
    struct Builder {
        let columns: Columns
        let file: String
        var table = RowTable()
        private var header = true
        private var interned: [String: UInt32] = [:]
        private var expected: [String] = []
        private var wanted: [Int] = []
        private var any = false
        private static let head = ["id", "suite", "scenario", "split", "epoch", "lag"]

        init(columns: Columns, file: String) {
            self.columns = columns
            self.file = file
            expected = Self.head + RunFiles.countColumns.map(\.name) + RunFiles.weightedColumns.map(\.name)
            switch columns {
            case .all:
                wanted = Array(RunFiles.countColumns.indices)
                table.weightedLoaded = true
            case let .only(paths):
                var wantedPaths = paths.map { $0 as AnyKeyPath }
                if wantedPaths.contains(where: { $0 == (\Metrics.fail as AnyKeyPath) }) { wantedPaths.append(\Metrics.exact as AnyKeyPath) }
                wanted = RunFiles.countColumns.indices.filter { index in
                    wantedPaths.contains { $0 == (RunFiles.countColumns[index].path as AnyKeyPath) }
                }
            }
            table.loaded = wanted
        }

        private mutating func intern(_ name: Substring) -> UInt32 {
            let name = String(name)
            if let found = interned[name] { return found }
            let number = UInt32(table.names.count)
            table.names.append(name)
            interned[name] = number
            return number
        }

        mutating func add(_ line: String) throws {
            if header {
                header = false
                guard line.split(separator: "\t").map(String.init) == expected else {
                    throw EvalError.input("\(file): the columns are not those of this version")
                }
                return
            }
            guard !line.isEmpty else { return }
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count == expected.count, let epoch = Int(f[4]).flatMap({ Int32(exactly: $0) }) else {
                throw EvalError.input("\(file): bad line")
            }
            var lag = RowTable.noLag
            if let value = Int(f[5]) {
                guard let small = Int32(exactly: value), small != RowTable.noLag else { throw EvalError.input("\(file): bad line") }
                lag = small
            }
            let head = Self.head.count
            for column in wanted {
                guard let value = Int(f[head + column]).flatMap({ Int32(exactly: $0) }) else {
                    throw EvalError.input("\(file): bad \(RunFiles.countColumns[column].name) in \(f[0])")
                }
                table.counts.append(value)
            }
            if table.weightedLoaded {
                for (slot, column) in RunFiles.weightedColumns.enumerated() {
                    guard let value = Double(f[head + RunFiles.countColumns.count + slot]) else {
                        throw EvalError.input("\(file): bad \(column.name) in \(f[0])")
                    }
                    table.weighted.append(value)
                }
            }
            table.ids.append(String(f[0]))
            table.suites.append(intern(f[1]))
            table.scenarios.append(intern(f[2]))
            table.splits.append(intern(f[3]))
            table.epochs.append(epoch)
            table.lags.append(lag)
        }

        /// A ready row, for `RowTable(_:)`.
        mutating func append(_ row: RunData.Row) {
            table.ids.append(row.id)
            table.suites.append(intern(row.suite[...]))
            table.scenarios.append(intern(row.scenario[...]))
            table.splits.append(intern(row.split[...]))
            table.epochs.append(Int32(row.epoch))
            table.lags.append(row.lag.map { Int32($0) } ?? RowTable.noLag)
            for column in wanted { table.counts.append(Int32(row.metrics[keyPath: RunFiles.countColumns[column].path])) }
            for column in RunFiles.weightedColumns { table.weighted.append(row.metrics[keyPath: column.path]) }
        }

        /// The table; a file with no line at all has no header either.
        func finish() throws -> RowTable {
            if header { throw EvalError.input("\(file): the columns are not those of this version") }
            return table
        }
    }
}
