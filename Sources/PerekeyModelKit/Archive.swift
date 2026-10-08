// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads compressed inputs through the system tools macOS ships: gzip, bzip2,
/// unzip, tar. The builder runs on developer machines and CI only, so a
/// `Process` is simpler than three decoders.
public enum Archive {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func gunzip(_ path: String) throws -> Data {
        try run("/usr/bin/gzip", ["-dc", path])
    }

    public static func bunzip2(_ path: String) throws -> Data {
        try run("/usr/bin/bzip2", ["-dc", path])
    }

    /// One member of a zip archive.
    public static func unzip(_ path: String, member: String) throws -> Data {
        try run("/usr/bin/unzip", ["-p", path, member])
    }

    /// One member of a .tar.bz2 archive.
    public static func untar(_ path: String, member: String) throws -> Data {
        try run("/usr/bin/tar", ["-xjOf", path, member])
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        // Read before waiting: the pipe fills up long before a 100 MB file ends.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(tool) \(arguments.joined(separator: " ")) failed: \(process.terminationStatus)")
        }
        return data
    }
}

extension Data {
    /// Lines of UTF-8 text, without line ends. A final line without "\n" counts.
    public func lines() -> [Substring] {
        String(decoding: self, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }
}
