// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The language counts of apps and sites (`LanguageStats`) as JSON in
/// Application Support, next to the settings but not in them.
///
/// A file of its own: the counts change every few dozen words, the settings
/// only when the user changes something, and every settings change goes to
/// the event tap and to disk. The counts describe this Mac, so the settings
/// export leaves them out by not knowing them. And a reset, or a file that
/// cannot be read, costs nothing but the counts: an unreadable file starts
/// over, nothing is set aside.
///
/// The file holds bundle IDs, hosts, language codes and numbers. Never a word.
public struct LanguageStatsFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "languages.json", directoryHint: .notDirectory)
    }

    public init(url: URL = LanguageStatsFile.defaultURL) {
        self.url = url
    }

    /// The saved counts; none if there is no file or it is unreadable.
    public func load() -> LanguageStats {
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(LanguageStats.self, from: data)
        else { return LanguageStats() }
        return stats
    }

    public func save(_ stats: LanguageStats) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(stats).write(to: url, options: .atomic)
    }

    /// The bytes `save` writes.
    public static func encode(_ stats: LanguageStats) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stats)
    }
}
