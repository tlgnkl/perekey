// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One unit of a source: a sentence with the reference that names it.
public struct SourceUnit: Hashable, Sendable {
    /// `tatoeba:rus#12345`, `post:12345#2`: the key of the dev/test split.
    public var ref: String
    /// The sentence, with `SourceText.codeOpen` and `codeClose` around inline code.
    public var text: String

    public init(ref: String, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// Runs a system tool and hands out its output line by line, as it comes.
/// A dump of a gigabyte is never held whole: `Archive.run` reads to the end,
/// this reader keeps one chunk and one line.
public enum LineStream {
    /// Calls `body` for each line as bytes, without the line end (`\n` or
    /// `\r\n`), until it returns false or the output ends. Throws if the
    /// tool fails.
    public static func read(tool: String, arguments: [String], body: ([UInt8]) throws -> Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let handle = output.fileHandleForReading
        var buffer: [UInt8] = []
        var stopped = false
        func emit(_ line: ArraySlice<UInt8>) throws {
            var line = line
            if line.last == 0x0D { line = line.dropLast() }
            if try !body(Array(line)) { stopped = true }
        }
        // The pool around `read`: its buffers are autoreleased and a loop over a big source never drains them.
        reading: while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            buffer.append(contentsOf: chunk)
            // The line ends, found with memchr; the used part goes once per chunk.
            var ends: [Int] = []
            buffer.withUnsafeBufferPointer { bytes in
                var from = 0
                while from < bytes.count, let found = memchr(bytes.baseAddress! + from, 0x0A, bytes.count - from) {
                    let end = bytes.baseAddress!.distance(to: found.assumingMemoryBound(to: UInt8.self))
                    ends.append(end)
                    from = end + 1
                }
            }
            var begin = 0
            for end in ends {
                try emit(buffer[begin..<end])
                begin = end + 1
                if stopped { break reading }
            }
            buffer.removeSubrange(0..<begin)
        }
        if stopped {
            process.terminate()
            process.waitUntilExit()
            return
        }
        if !buffer.isEmpty { try emit(buffer[...]) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EvalError.input("\(tool) \(arguments.joined(separator: " ")) failed: \(process.terminationStatus)")
        }
    }
}

/// A unit that is not made yet: the hash of its reference is known, the
/// strings are built on demand. The builder keeps a unit only if its rank
/// is among the first ones, and building two strings for each of millions
/// of sentences would cost most of the read.
public struct PendingUnit {
    enum Storage {
        case ready(SourceUnit)
        /// The sentence at `range` of a paragraph of the post `prefix` ends with its `number`.
        case sentence(prefix: [UInt8], number: Int, paragraph: [UInt8], range: Range<Int>)
    }

    let storage: Storage

    public func make() -> SourceUnit {
        switch storage {
        case let .ready(unit): unit
        case let .sentence(prefix, number, paragraph, range):
            SourceUnit(ref: String(decoding: prefix, as: UTF8.self) + String(number),
                       text: String(decoding: paragraph[range], as: UTF8.self))
        }
    }
}

/// Reads the units of a manifest's sources from the data cache.
public enum SourceReader {
    /// Calls `body` for every unit of every source file, in file order, with
    /// the number of the file among the manifest's sources, the FNV-1a hash
    /// of the unit's reference and a way to make the unit.
    public static func forEachUnit(_ manifest: SuiteManifest, cache: String,
                                   body: (_ source: Int, _ refHash: UInt64, _ unit: PendingUnit) throws -> Void) throws
    {
        for (index, source) in manifest.sources.enumerated() {
            let path = (cache as NSString).appendingPathComponent(source)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("\(manifest.suite): no source file \(path); run scripts/fetch-data.sh heldout")
            }
            switch manifest.reader {
            case .tatoeba, .class: try TatoebaReader.forEachLazyUnit(path: path) { try body(index, $0, $1) }
            case .stackexchange: try StackExchangeReader.forEachLazyUnit(path: path) { try body(index, $0, $1) }
            case .misspellings, .typopairs:
                throw EvalError.input("\(manifest.suite): the reader \(manifest.reader.rawValue) reads pairs, not sentences")
            }
        }
    }
}

/// Tatoeba exports: `id`, `lang`, `text`, tab-separated, bzip2.
public enum TatoebaReader {
    public static func forEachLazyUnit(path: String, body: (UInt64, PendingUnit) throws -> Void) throws {
        try LineStream.read(tool: "/usr/bin/bzip2", arguments: ["-dc", path]) { bytes in
            if let unit = unit(fromLine: String(decoding: bytes, as: UTF8.self)[...]) { try body(FNV1a.hash64(unit.ref), PendingUnit(storage: .ready(unit))) }
            return true
        }
    }

    public static func forEachUnit(path: String, body: (SourceUnit) throws -> Void) throws {
        try forEachLazyUnit(path: path) { _, pending in try body(pending.make()) }
    }

    /// `12345\trus\tПривет, мир.` to a unit; nil for a line of another shape.
    public static func unit(fromLine line: Substring) -> SourceUnit? {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[2].isEmpty else { return nil }
        return SourceUnit(ref: "tatoeba:\(fields[1])#\(fields[0])", text: String(fields[2]))
    }
}

/// Stack Exchange dumps: `Posts.xml` of a `.7z`, read by the system `tar`
/// as a stream.
public enum StackExchangeReader {
    public static func forEachLazyUnit(path: String, body: (UInt64, PendingUnit) throws -> Void) throws {
        try LineStream.read(tool: "/usr/bin/tar", arguments: ["-xOf", path, "Posts.xml"]) { row in
            try forEachSentence(inRow: row, body: body)
            return true
        }
    }

    public static func forEachUnit(path: String, body: (SourceUnit) throws -> Void) throws {
        try forEachLazyUnit(path: path) { _, pending in try body(pending.make()) }
    }

    /// The sentences of the post a `<row …/>` line holds: the unit is a
    /// sentence, its reference `post:<Id>#<n>`, `n` the number of the
    /// sentence in the post, from 0.
    public static func units(fromRow line: Substring) -> [SourceUnit] {
        var units: [SourceUnit] = []
        try? forEachSentence(inRow: Array(line.utf8)) { _, pending in units.append(pending.make()) }
        return units
    }

    static func forEachSentence(inRow row: [UInt8], body: (UInt64, PendingUnit) throws -> Void) throws {
        guard let id = attribute("Id", in: row), let value = attribute("Body", in: row) else { return }
        let prefix = Array("post:".utf8) + id + Array("#".utf8)
        var number = 0
        for paragraph in SourceText.paragraphBytes(fromBody: value) {
            for range in SourceText.sentenceRanges(in: paragraph) {
                let n = number
                number += 1
                let hashed = FNV1a.hash64(prefix + Array(String(n).utf8))
                try body(hashed, PendingUnit(storage: .sentence(prefix: prefix, number: n, paragraph: paragraph,
                                                                 range: range)))
            }
        }
    }

    /// The raw bytes of ` Name="…"`. The space in front keeps `ParentId`
    /// and `OwnerUserId` from passing for `Id`.
    static func attribute(_ name: String, in row: [UInt8]) -> [UInt8]? {
        let pattern = Array(" \(name)=\"".utf8)
        guard row.count > pattern.count else { return nil }
        var index = 0
        while index <= row.count - pattern.count {
            if row[index] == pattern[0], row[index..<(index + pattern.count)].elementsEqual(pattern) {
                let start = index + pattern.count
                guard let end = row[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
                return Array(row[start..<end])
            }
            index += 1
        }
        return nil
    }
}
