// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore

/// The text rules and history settings: `VoiceTextSettings` as JSON in
/// Application Support, beside `voice.json`.
///
/// A file of its own, as `voice.json` is: an older Perekey does not read it,
/// and the dictionary the user typed is not lost when they go back. Keys this
/// version does not know stay on save. A file of a newer `schemaVersion` is
/// read and never overwritten. A file that cannot be read is moved aside.
public struct VoiceTextSettingsFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        SettingsFile.defaultURL.deletingLastPathComponent()
            .appending(path: "voice-text.json", directoryHint: .notDirectory)
    }

    public init(url: URL = VoiceTextSettingsFile.defaultURL) {
        self.url = url
    }

    public var brokenURL: URL {
        url.deletingLastPathComponent().appending(path: "voice-text.broken.json", directoryHint: .notDirectory)
    }

    /// The saved settings; the defaults if there is no file or it is unreadable.
    public func load() -> VoiceTextSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return VoiceTextSettings()
        } catch {
            setAside()
            return VoiceTextSettings()
        }
        do {
            return try JSONDecoder().decode(VoiceTextSettings.self, from: data)
        } catch {
            setAside()
            return VoiceTextSettings()
        }
    }

    /// The file on disk is of a newer version: `save` leaves it alone.
    public struct NewerVersionError: Error, Equatable {
        public let schemaVersion: Int
    }

    public func save(_ settings: VoiceTextSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let theirs = object["schemaVersion"] as? Int, theirs > VoiceTextSettings.schemaVersion {
            throw NewerVersionError(schemaVersion: theirs)
        }
        let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
        object.merge(ours) { _, new in new }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private func setAside() {
        let manager = FileManager.default
        try? manager.removeItem(at: brokenURL)
        try? manager.moveItem(at: url, to: brokenURL)
    }
}
