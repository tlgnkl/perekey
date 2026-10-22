// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The shadow journal of learning (`LearningJournal`) as JSON in Application
/// Support, next to the settings but not in them: it describes this Mac's
/// use, so the settings export leaves it out by not knowing it. A file that
/// cannot be read starts over.
///
/// The file holds bundle IDs, times, kinds and numbers. Never a word.
public struct LearningJournalFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "learning-journal.json", directoryHint: .notDirectory)
    }

    public init(url: URL = LearningJournalFile.defaultURL) {
        self.url = url
    }

    /// The saved journal; an empty one if there is no file or it is unreadable.
    public func load() -> LearningJournal {
        guard let data = try? Data(contentsOf: url),
              let journal = try? JSONDecoder().decode(LearningJournal.self, from: data)
        else { return LearningJournal() }
        return journal
    }

    public func save(_ journal: LearningJournal) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    /// Adds one entry to the file.
    public func append(_ entry: LearningJournal.Entry) throws {
        var journal = load()
        journal.append(entry)
        try save(journal)
    }
}
