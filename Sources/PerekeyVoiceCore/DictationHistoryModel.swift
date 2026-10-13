// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How long dictations stay on disk.
public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case off
    case day
    case week
    case month

    public static let `default` = HistoryRetention.week

    /// Days kept; 0 keeps nothing.
    public var days: Int {
        switch self {
        case .off: 0
        case .day: 1
        case .week: 7
        case .month: 30
        }
    }

    /// The term in force: the user's choice, cut down by the profile's limit.
    /// A limit between two terms leaves the longest term that fits, or `.off`.
    public func limited(byMaxDays maxDays: Int?) -> HistoryRetention {
        guard let maxDays else { return self }
        return Self.allCases.last { $0.days <= maxDays && $0.days <= days } ?? .off
    }
}

/// What a dictation was typed into, as far as the history may keep it.
public enum DictationPrivacy: Equatable, Sendable {
    case normal
    /// The focus is a password field.
    case secureField
    /// Secure Input is on in some process.
    case secureInput
}

/// One dictation in the history.
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var bundleID: String?
    public var appName: String?
    public var date: Date
    /// Seconds of speech.
    public var duration: Double
    /// The id of the model that recognized it (`ModelCatalog` entry).
    public var model: String
    /// The text went into the field; false when the paste did not happen.
    public var pasted: Bool
    /// The audio file `<id>.aac` is kept beside the history.
    public var hasAudio: Bool

    public init(id: UUID = UUID(), text: String, bundleID: String? = nil, appName: String? = nil, date: Date,
                duration: Double, model: String, pasted: Bool, hasAudio: Bool = false)
    {
        self.id = id
        self.text = text
        self.bundleID = bundleID
        self.appName = appName
        self.date = date
        self.duration = duration
        self.model = model
        self.pasted = pasted
        self.hasAudio = hasAudio
    }

    /// Words by the same count the statistics use.
    public var wordCount: Int { DictationHistoryText.wordCount(text) }
}

public enum DictationHistoryText {
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// The first `limit` characters of a one-line text, for the menu.
    public static func preview(_ text: String, limit: Int = 40) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard line.count > limit else { return line }
        return line.prefix(limit).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}

/// The text rules and the history as the user set them (`voice-text.json`).
public struct VoiceTextSettings: Equatable, Sendable {
    /// The version of the file's layout. A file of a higher version is read
    /// and never overwritten.
    public static let schemaVersion = 1

    public var dictionary: [DictionaryEntry]
    /// Remove "э-э", "um" and the like.
    public var removesFillers: Bool
    public var retention: HistoryRetention
    /// Keep the audio of dictations beside their text.
    public var keepsAudio: Bool
    /// Show the start of the text in the menu; off shows only the time and the app.
    public var showsTextInMenu: Bool
    /// The file is of a newer version: shown, not changed.
    public private(set) var newerSchemaVersion: Int?

    public init(dictionary: [DictionaryEntry] = TextRules.defaultDictionary, removesFillers: Bool = true,
                retention: HistoryRetention = .default, keepsAudio: Bool = false, showsTextInMenu: Bool = true)
    {
        self.dictionary = dictionary
        self.removesFillers = removesFillers
        self.retention = retention
        self.keepsAudio = keepsAudio
        self.showsTextInMenu = showsTextInMenu
    }
}

extension VoiceTextSettings: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, dictionary, removesFillers, retention, keepsAudio, showsTextInMenu
    }

    /// Tolerant: a key that is missing or unreadable falls back to its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceTextSettings()
        dictionary = (try? container.decode([DictionaryEntry].self, forKey: .dictionary)) ?? defaults.dictionary
        removesFillers = (try? container.decode(Bool.self, forKey: .removesFillers)) ?? defaults.removesFillers
        retention = (try? container.decode(HistoryRetention.self, forKey: .retention)) ?? defaults.retention
        keepsAudio = (try? container.decode(Bool.self, forKey: .keepsAudio)) ?? defaults.keepsAudio
        showsTextInMenu = (try? container.decode(Bool.self, forKey: .showsTextInMenu)) ?? defaults.showsTextInMenu
        if let version = try? container.decode(Int.self, forKey: .schemaVersion), version > Self.schemaVersion {
            newerSchemaVersion = version
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(dictionary, forKey: .dictionary)
        try container.encode(removesFillers, forKey: .removesFillers)
        try container.encode(retention, forKey: .retention)
        try container.encode(keepsAudio, forKey: .keepsAudio)
        try container.encode(showsTextInMenu, forKey: .showsTextInMenu)
    }
}
