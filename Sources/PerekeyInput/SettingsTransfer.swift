// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Export and import of the settings as a JSON file the user keeps.
///
/// The file is `AppSettings` plus a `"version"` number. Import is strict where
/// the settings file is tolerant: the user picked this file on purpose, so a
/// wrong one must produce an error, not silent defaults.
public enum SettingsTransfer {
    /// The file format this build writes and the newest it reads.
    /// 2: `words.always` ("Всегда исправлять") and the undo count of learned
    /// words. Version 1 files load with both empty: one undo per learned word.
    /// The other way is lossy: a Perekey from before version 2 reads a newer
    /// settings file, but silently drops `always` and `undoCount` on its first save.
    public static let currentVersion = 2

    private static let knownKeys: Set<String> = ["hotkeys", "capsLock", "autoswitch", "onboardingDone", "words"]

    public enum ImportError: Error, Equatable, LocalizedError {
        case notSettings
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notSettings:
                String(localized: "The file is not a Perekey settings file.")
            case let .newerVersion(version):
                String(localized: "The file comes from a newer Perekey (format \(version)). Update Perekey and try again.")
            }
        }
    }

    /// What an import would bring, for the confirmation.
    public struct Summary: Equatable, Sendable {
        public var shortcuts: Int
        public var words: Int
        /// Apps with a rule of their own.
        public var apps: Int

        public init(shortcuts: Int, words: Int, apps: Int = 0) {
            self.shortcuts = shortcuts
            self.words = words
            self.apps = apps
        }

        public init(_ settings: AppSettings) {
            self.init(shortcuts: settings.hotkeys.count, words: settings.words.count, apps: settings.apps.count)
        }
    }

    /// Pretty JSON with sorted keys, so two exports of the same settings are the same bytes.
    public static func export(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(settings)
        guard var object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw ImportError.notSettings
        }
        object["version"] = currentVersion
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Validates and decodes a file. Throws `ImportError` for anything that is not settings.
    public static func importSettings(from data: Data) throws -> AppSettings {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !Self.knownKeys.isDisjoint(with: object.keys)
        else { throw ImportError.notSettings }
        if let raw = object["version"] {
            guard let version = raw as? Int, version >= 1 else { throw ImportError.notSettings }
            if version > currentVersion { throw ImportError.newerVersion(version) }
        }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            throw ImportError.notSettings
        }
        return settings
    }
}
