// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyVoiceCore

/// The dictation modes file: `VoiceModeSet` as JSON in Application Support,
/// beside `voice.json`. Like that file: keys this version does not know are
/// kept on save, a file of a newer `schemaVersion` is read but never
/// written, and a file that cannot be read is moved aside. API keys are not
/// in it: they live in the Keychain (`VoiceKeychain`).
public struct VoiceModesFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        VoiceSettingsFile.defaultURL.deletingLastPathComponent()
            .appending(path: "voice-modes.json", directoryHint: .notDirectory)
    }

    public init(url: URL = VoiceModesFile.defaultURL) {
        self.url = url
    }

    public var brokenURL: URL {
        url.deletingLastPathComponent().appending(path: "voice-modes.broken.json", directoryHint: .notDirectory)
    }

    /// The saved modes; `defaults` when there is no file or it is unreadable.
    public func load(defaults: @autoclosure () -> VoiceModeSet) -> VoiceModeSet {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return defaults()
        } catch {
            setAside()
            return defaults()
        }
        do {
            return try JSONDecoder().decode(VoiceModeSet.self, from: data)
        } catch {
            setAside()
            return defaults()
        }
    }

    public struct NewerVersionError: Error, Equatable {
        public let schemaVersion: Int
    }

    /// Writes the file atomically over the keys of the one on disk. A file of
    /// a newer `schemaVersion` is never overwritten.
    public func save(_ modes: VoiceModeSet) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let theirs = object["schemaVersion"] as? Int, theirs > VoiceModeSet.schemaVersion {
            throw NewerVersionError(schemaVersion: theirs)
        }
        let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modes)) as? [String: Any] ?? [:]
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
