// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import PerekeyCore

/// The dictation settings file: `VoiceSettings` as JSON in Application
/// Support, beside `settings.json`.
///
/// Dictation keeps out of `settings.json`: an older Perekey drops the whole
/// file it cannot decode, and a new shortcut action there would cost a user
/// who goes back every setting they had. This file is new; an older Perekey
/// does not read it.
///
/// Keys this version does not know are kept on save: a newer version may
/// have written them, and the user may go back and forth. A file that cannot
/// be read is moved aside, as `SettingsFile` does.
public struct VoiceSettingsFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        SettingsFile.defaultURL.deletingLastPathComponent()
            .appending(path: "voice.json", directoryHint: .notDirectory)
    }

    public init(url: URL = VoiceSettingsFile.defaultURL) {
        self.url = url
    }

    /// Where an unreadable file goes.
    public var brokenURL: URL {
        url.deletingLastPathComponent().appending(path: "voice.broken.json", directoryHint: .notDirectory)
    }

    /// The saved settings; dictation off if there is no file or it is unreadable.
    public func load() -> VoiceSettings {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return VoiceSettings()
        } catch {
            setAside()
            return VoiceSettings()
        }
        do {
            return try JSONDecoder().decode(VoiceSettings.self, from: data)
        } catch {
            setAside()
            return VoiceSettings()
        }
    }

    /// Writes the file atomically, over the keys of the file on disk: those
    /// this version does not know stay as they are.
    public func save(_ settings: VoiceSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] ?? [:]
        // A newer version's file keeps its version: it may read keys of ours differently.
        let version = "schemaVersion"
        let theirVersion = object[version] as? Int ?? 0
        object.merge(ours) { _, new in new }
        object[version] = max(theirVersion, VoiceSettings.schemaVersion)
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

public extension VoiceTrigger {
    /// Whether the hold trigger's key and modifiers are down now, as the
    /// window server sees them. Main thread, while a hold is on: four times a
    /// second is enough to end a hold whose key up the tap lost
    /// (`InputEvent.voiceHoldLost`). Always false for a tap trigger.
    var isHeldNow: Bool {
        guard case let .hold(keyCode, modifiers) = self else { return false }
        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return modifiers.allSatisfy { kind in
            switch kind {
            case .shift: flags.contains(.maskShift)
            case .control: flags.contains(.maskControl)
            case .option: flags.contains(.maskAlternate)
            case .command: flags.contains(.maskCommand)
            case .function: true
            }
        }
    }
}
