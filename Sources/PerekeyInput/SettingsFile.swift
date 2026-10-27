// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The settings file: `AppSettings` as JSON in Application Support.
///
/// A file that cannot be read is moved aside, not overwritten: the next save
/// would otherwise destroy what the user had, and a bug in decoding could then
/// cost them every shortcut they recorded.
public struct SettingsFile: Sendable {
    public let url: URL
    /// Holds the mark that the learning migration ran (`WordRules.migratesLearningKey`).
    /// Outside `settings.json`: an older build rewrites that file without the mark.
    private nonisolated(unsafe) let defaults: UserDefaults
    private static let migratedKey = "learningMigrated"

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "settings.json", directoryHint: .notDirectory)
    }

    public init(url: URL = SettingsFile.defaultURL, defaults: UserDefaults) {
        self.url = url
        self.defaults = defaults
    }

    /// Where an unreadable file goes.
    public var brokenURL: URL {
        url.deletingLastPathComponent().appending(path: "settings.broken.json", directoryHint: .notDirectory)
    }

    /// The saved settings; defaults if there is no file or it is unreadable.
    public func load() -> AppSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Nothing to migrate: the mark is set once the first file is written.
            let settings = AppSettings()
            if (try? save(settings)) != nil { defaults.set(true, forKey: Self.migratedKey) }
            return settings
        } catch {
            setAside()
            return AppSettings()
        }
        do {
            let decoder = JSONDecoder()
            let migrates = !defaults.bool(forKey: Self.migratedKey)
            decoder.userInfo[WordRules.migratesLearningKey] = migrates
            decoder.userInfo[WordRules.migratedAtKey] = Date().timeIntervalSince1970
            let settings = try decoder.decode(AppSettings.self, from: data)
            // The migrated settings live in memory until saved: a quit before the first change would
            // lose them with the mark set. The mark goes on only after the write.
            if migrates {
                if (try? save(settings)) != nil { defaults.set(true, forKey: Self.migratedKey) }
            }
            return settings
        } catch {
            setAside()
            return AppSettings()
        }
    }

    /// Writes the file atomically, so a crash never leaves half a file.
    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    private func setAside() {
        let manager = FileManager.default
        try? manager.removeItem(at: brokenURL)
        try? manager.moveItem(at: url, to: brokenURL)
    }
}
