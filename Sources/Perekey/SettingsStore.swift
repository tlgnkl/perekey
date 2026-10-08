// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os
import PerekeyCore
import PerekeyInput

/// The user's settings in memory. Every change goes to disk at once, and the
/// Caps Lock mode goes to the system.
@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: AppSettings

    /// True while a shortcut recorder listens. A future event tap pauses the
    /// hotkeys then, so the keys being recorded do not also run actions.
    var isRecording = false

    /// Set when the system refused a Caps Lock change.
    private(set) var capsLockFailed = false

    @ObservationIgnored private let file: SettingsFile
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "settings")

    /// Loads the file and applies the Caps Lock mode. Applying on launch also
    /// removes the remap a crashed run left behind when the mode is not `.instant`.
    init(file: SettingsFile = SettingsFile()) {
        self.file = file
        settings = file.load()
        CapsLockRemapper.apply(settings.capsLock)
    }

    /// What the event tap reads.
    var snapshot: PerekeyCore.Settings { settings.snapshot }

    func update(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        do {
            try file.save(copy)
        } catch {
            log.error("Cannot save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Changes the Caps Lock mode. The setting stays as it was if the system refuses.
    func setCapsLock(_ mode: CapsLockMode) {
        capsLockFailed = !CapsLockRemapper.apply(mode)
        guard !capsLockFailed else { return }
        update { $0.capsLock = mode }
    }
}
