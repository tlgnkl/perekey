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
    /// Calls `body` for each line, without the line end (`\n` or `\r\n`),
    /// until it returns false or the output ends. Throws if the tool fails.
    public static func read(tool: String, arguments: [String], body: (Substring) throws -> Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let handle = output.fileHandleForReading
        var pending = Data()
        var stopped = false
        func emit(_ bytes: Data) throws {
            var line = String(decoding: bytes, as: UTF8.self)[...]
            if line.hasSuffix("\r") { line = line.dropLast() }
            if try !body(line) { stopped = true }
        }
        reading: while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            // Cut the lines by offset and drop the used part once per chunk:
            // removing from the front of the buffer per line is quadratic.
            var begin = pending.startIndex
            while let newline = pending[begin...].firstIndex(of: 0x0A) {
                try emit(pending[begin..<newline])
                begin = pending.index(after: newline)
                if stopped { break reading }
            }
            pending = Data(pending[begin...])
        }
        if stopped {
            process.terminate()
            process.waitUntilExit()
            return
        }
        if !pending.isEmpty { try emit(pending) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EvalError.input("\(tool) \(arguments.joined(separator: " ")) failed: \(process.terminationStatus)")
        }
    }
}

/// Reads the units of a manifest's sources from the data cache.
public enum SourceReader {
    /// Calls `body` for every unit of every source file, in file order, with
    /// the number of the file among the manifest's sources.
    public static func forEachUnit(_ manifest: SuiteManifest, cache: String,
                                   body: (_ source: Int, _ unit: SourceUnit) throws -> Void) throws
    {
        for (index, source) in manifest.sources.enumerated() {
            let path = (cache as NSString).appendingPathComponent(source)
            guard FileManager.default.fileExists(atPath: path) else {
                throw EvalError.input("\(manifest.suite): no source file \(path); run scripts/fetch-data.sh heldout")
            }
            switch manifest.reader {
            case .tatoeba: try TatoebaReader.forEachUnit(path: path) { try body(index, $0) }
            case .stackexchange: try StackExchangeReader.forEachUnit(path: path) { try body(index, $0) }
            }
        }
    }
}

/// Tatoeba exports: `id`, `lang`, `text`, tab-separated, bzip2.
public enum TatoebaReader {
    public static func forEachUnit(path: String, body: (SourceUnit) throws -> Void) throws {
        try LineStream.read(tool: "/usr/bin/bzip2", arguments: ["-dc", path]) { line in
            if let unit = unit(fromLine: line) { try body(unit) }
            return true
        }
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
    public static func forEachUnit(path: String, body: (SourceUnit) throws -> Void) throws {
        try LineStream.read(tool: "/usr/bin/tar", arguments: ["-xOf", path, "Posts.xml"]) { line in
            for unit in units(fromRow: line) { try body(unit) }
            return true
        }
    }

    /// The sentences of the post a `<row …/>` line holds: the unit is a
    /// sentence, its reference `post:<Id>#<n>`, `n` the number of the
    /// sentence in the post, from 0.
    public static func units(fromRow line: Substring) -> [SourceUnit] {
        guard let id = attribute("Id", in: line), let body = attribute("Body", in: line) else { return [] }
        var units: [SourceUnit] = []
        for paragraph in SourceText.paragraphs(fromBody: body) {
            for sentence in SourceText.sentences(of: paragraph) {
                units.append(SourceUnit(ref: "post:\(id)#\(units.count)", text: sentence))
            }
        }
        return units
    }

    /// The raw value of ` Name="…"`. The space in front keeps `ParentId`
    /// and `OwnerUserId` from passing for `Id`. Searches the bytes: the
    /// rows of a dump are a gigabyte of text.
    static func attribute(_ name: String, in line: Substring) -> String? {
        let pattern = Array(" \(name)=\"".utf8)
        let bytes = line.utf8
        var index = bytes.startIndex
        var match: String.Index?
        search: while index < bytes.endIndex {
            if bytes[index] == pattern[0] {
                var probe = index
                for byte in pattern {
                    guard probe < bytes.endIndex, bytes[probe] == byte else {
                        index = bytes.index(after: index)
                        continue search
                    }
                    probe = bytes.index(after: probe)
                }
                match = probe
                break
            }
            index = bytes.index(after: index)
        }
        guard let start = match, let end = bytes[start...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(line[start..<end])
    }
}
