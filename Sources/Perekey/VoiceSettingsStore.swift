// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import Foundation
import Observation
import os
import PerekeyCore
import PerekeyInput

/// The dictation settings in memory (`voice.json`). Every change goes to disk
/// at once, as `SettingsStore` does for `settings.json`.
@MainActor
@Observable
final class VoiceSettingsStore {
    private(set) var settings: VoiceSettings
    /// What the organization's profile forces for voice.
    let managed: ManagedSettings

    /// Called after any change.
    @ObservationIgnored private var observers: [@MainActor () -> Void] = []

    @ObservationIgnored private let file: VoiceSettingsFile
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "voice-settings")

    init(file: VoiceSettingsFile = VoiceSettingsFile(), managed: ManagedSettings = ManagedPreferences.read()) {
        self.file = file
        self.managed = managed
        settings = file.load()
    }

    /// Calls `handler` after every change, and once now.
    func observe(_ handler: @escaping @MainActor () -> Void) {
        observers.append(handler)
        handler()
    }

    /// The file was written by a newer Perekey: its settings are shown, and not changed.
    var isLocked: Bool { settings.newerSchemaVersion != nil }

    /// The switch as the user set it, unless a profile turns voice off or the
    /// file is of a newer version.
    var isOn: Bool { settings.isEnabled && !managed.voiceDisabled && !isLocked }

    func update(_ change: (inout VoiceSettings) -> Void) {
        // `VoiceSettingsFile.save` would refuse anyway; the memory must not drift from the disk.
        guard !isLocked else { return }
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        observers.forEach { $0() }
        do {
            try file.save(copy)
        } catch {
            log.error("Cannot save voice settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
