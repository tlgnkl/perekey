// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os
import PerekeyCore
import PerekeyVoiceCore

/// The text rules and history settings in memory (`voice-text.json`). Every
/// change goes to disk at once, as `VoiceSettingsStore` does for `voice.json`.
@MainActor
@Observable
public final class VoiceTextStore {
    public private(set) var settings: VoiceTextSettings
    /// What the organization's profile forces.
    public let managed: ManagedSettings

    @ObservationIgnored private var observers: [@MainActor () -> Void] = []
    @ObservationIgnored private let file: VoiceTextSettingsFile?
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "voice-text")

    /// `file`: nil keeps the settings in memory only (previews, tests).
    public init(file: VoiceTextSettingsFile? = VoiceTextSettingsFile(), managed: ManagedSettings = ManagedSettings()) {
        self.file = file
        self.managed = managed
        settings = file?.load() ?? VoiceTextSettings()
    }

    /// Calls `handler` after every change, and once now.
    public func observe(_ handler: @escaping @MainActor () -> Void) {
        observers.append(handler)
        handler()
    }

    /// The file was written by a newer Perekey: shown, not changed.
    public var isLocked: Bool { settings.newerSchemaVersion != nil }

    /// The term the profile allows: the user's choice, cut down by the limit.
    public var effectiveRetention: HistoryRetention {
        settings.retention.limited(byMaxDays: managed.voiceHistoryMaxDays)
    }

    /// The terms the user may pick: those the profile's limit leaves.
    public var availableRetentions: [HistoryRetention] {
        HistoryRetention.allCases.filter { $0.limited(byMaxDays: managed.voiceHistoryMaxDays) == $0 }
    }

    public func update(_ change: (inout VoiceTextSettings) -> Void) {
        guard !isLocked else { return }
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        observers.forEach { $0() }
        do {
            try file?.save(copy)
        } catch {
            log.error("Cannot save voice text settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Dictionary

    /// Adds a replacement, or changes the one with the same "from". False for an empty side.
    @discardableResult
    public func setEntry(from: String, to: String) -> Bool {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return false }
        update { settings in
            if let index = settings.dictionary.firstIndex(where: { $0.id == from.lowercased() }) {
                settings.dictionary[index] = DictionaryEntry(from: from, to: to)
            } else {
                settings.dictionary.append(DictionaryEntry(from: from, to: to))
            }
        }
        return true
    }

    public func removeEntry(_ entry: DictionaryEntry) {
        update { $0.dictionary.removeAll { $0.id == entry.id } }
    }
}
