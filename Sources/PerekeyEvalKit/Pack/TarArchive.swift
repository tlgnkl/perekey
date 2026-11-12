// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A tar archive whose bytes depend only on the files: paths in byte order, owner 0, mode 0644, time 0, no
/// user names. The same files give the same archive on any day and any machine (docs/eval.md, «Пакет случаев»).
/// Format: ustar, padded to a record of 10240 bytes as `tar` does.
enum TarArchive {
    struct Entry: Equatable {
        var path: String
        var data: Data
    }

    private static let block = 512
    private static let record = 10240
    /// The size field holds 11 octal digits.
    private static let sizeLimit = 1 << 33

    static func bytes(_ entries: [Entry]) throws -> Data {
        var archive = Data()
        let sorted = entries.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        for entry in sorted {
            archive += try header(entry)
            archive += entry.data
            archive += Data(count: (block - entry.data.count % block) % block)
        }
        archive += Data(count: 2 * block)
        archive += Data(count: (record - archive.count % record) % record)
        return archive
    }

    private static func header(_ entry: Entry) throws -> Data {
        guard entry.data.count < sizeLimit else { throw EvalError.input("pack: \(entry.path) is too large for a tar header") }
        let (prefix, name) = try split(entry.path)
        var header = [UInt8](repeating: 0, count: block)
        func put(_ text: [UInt8], at offset: Int) { header.replaceSubrange(offset..<offset + text.count, with: text) }
        func octal(_ value: Int, digits: Int) -> [UInt8] {
            let text = String(value, radix: 8)
            return Array((String(repeating: "0", count: max(0, digits - text.count)) + text).utf8)
        }
        put(name, at: 0)
        put(octal(0o644, digits: 7), at: 100)
        put(octal(0, digits: 7), at: 108)
        put(octal(0, digits: 7), at: 116)
        put(octal(entry.data.count, digits: 11), at: 124)
        put(octal(0, digits: 11), at: 136)
        put(Array(repeating: UInt8(ascii: " "), count: 8), at: 148)
        header[156] = UInt8(ascii: "0")
        put(Array("ustar".utf8), at: 257)
        put(Array("00".utf8), at: 263)
        put(octal(0, digits: 7), at: 329)
        put(octal(0, digits: 7), at: 337)
        put(prefix, at: 345)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(octal(sum, digits: 6), at: 148)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        return Data(header)
    }

    /// The path as the header keeps it: a prefix of up to 155 bytes and a name of up to 100, cut at a slash.
    private static func split(_ path: String) throws -> (prefix: [UInt8], name: [UInt8]) {
        let bytes = Array(path.utf8)
        if bytes.count <= 100 { return ([], bytes) }
        for index in bytes.indices.reversed() where bytes[index] == UInt8(ascii: "/") {
            if index <= 155, bytes.count - index - 1 <= 100, bytes.count - index - 1 > 0 {
                return (Array(bytes[..<index]), Array(bytes[(index + 1)...]))
            }
        }
        throw EvalError.input("pack: the path \(path) does not fit a tar header")
    }
}

/// `zstd`, the program: the pack is compressed with it, at a fixed level and one thread, so that the same
/// tar gives the same bytes with the same version of the program.
enum Zstd {
    /// The level of the pack: the highest that does not need extra memory to unpack.
    static let level = 19

    static func executable() throws -> String {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = directory + "/zstd"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw EvalError.input("pack: zstd is not installed (brew install zstd)")
    }

    /// Compresses the file `input` into `output`.
    static func compress(_ input: String, to output: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executable())
        process.arguments = ["-q", "-f", "-\(level)", "-T1", input, "-o", output]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EvalError.input("pack: zstd exited with status \(process.terminationStatus)")
        }
    }
}
