// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The files of `scripts/fetch-data.sh` that the pair counts train on, and
/// the check that none of them is a file something is measured on
/// (plan, 2.4 point 3: training and held-out text do not meet).
///
/// The script lists every file as `group|path in cache|url|sha256`. The
/// group `pairs` is training text. The groups `text`, `wikifreq` and
/// `heldout` are what the classifier, the hyphen step and the pair table
/// are measured on or counted for; none of them may share a file with `pairs`.
public enum PairSources {
    public struct Source: Equatable, Sendable {
        public var group: String
        public var path: String
        public var url: String
        public var sha256: String
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Groups whose files are measured on, or counted for something else.
    public static let heldOut: Set = ["text", "wikifreq", "heldout"]

    /// Every row of the `SOURCES` block of the script.
    public static func rows(of script: String) -> [Source] {
        script.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 4, !line.hasPrefix("#"), !line.hasPrefix(" "),
                  ["lexicon", "text", "pairs", "wikifreq", "heldout", "heavy", "fallback"].contains(String(fields[0]))
            else { return nil }
            return Source(group: String(fields[0]), path: String(fields[1]), url: String(fields[2]),
                          sha256: String(fields[3]))
        }
    }

    /// The problems of the lists: an empty array when the training files are
    /// apart from the held-out ones and all in `wikipedia-pairs/<language>/`.
    public static func problems(in script: String) -> [String] {
        let rows = rows(of: script)
        let training = rows.filter { $0.group == "pairs" }
        let held = rows.filter { heldOut.contains($0.group) }
        var problems: [String] = []
        if training.isEmpty { problems.append("the group `pairs` has no file") }
        for file in training {
            if !file.path.hasPrefix("wikipedia-pairs/") {
                problems.append("\(file.path): training files live in wikipedia-pairs/, where scripts/wiki-text.py reads them")
            }
            for other in held where other.url == file.url || (file.sha256 != "-" && other.sha256 == file.sha256)
                || Self.name(other.path) == Self.name(file.path)
            {
                problems.append("\(file.path) is also held out as \(other.path) (group \(other.group))")
            }
        }
        return problems
    }

    /// The last two components of a path: `ru/train-00007-of-00021.parquet`.
    private static func name(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    /// Throws when the lists share a file, or when `files` (the names in
    /// `wikipedia-pairs/<language>/` of the cache) holds one the script does not list.
    public static func check(script: String, cachedFiles: [String]) throws {
        var problems = Self.problems(in: script)
        let listed = Set(rows(of: script).filter { $0.group == "pairs" }.map(\.path))
        for file in cachedFiles where !listed.contains(file) {
            problems.append("\(file) is in the cache but not in the group `pairs` of scripts/fetch-data.sh")
        }
        guard problems.isEmpty else {
            throw Failure(description: "training text and held-out text meet:\n  " + problems.joined(separator: "\n  "))
        }
    }
}
