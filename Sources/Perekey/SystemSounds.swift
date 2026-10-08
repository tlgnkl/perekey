// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore

/// The sounds macOS ships in /System/Library/Sounds. Perekey bundles none.
@MainActor
enum SystemSounds {
    private static let directory = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)

    /// The names to pick from ("Glass", "Tink"…), sorted.
    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(".aiff".count)) }.sorted()
    }()

    /// Kept until it ends: a sound released at once is cut off.
    private static var playing: NSSound?

    /// Plays the sound if it is on and its file exists. Main thread.
    static func play(_ setting: SoundSetting) {
        if setting.isOn { play(named: setting.name) }
    }

    /// Plays one sound, e.g. as a preview in the picker.
    static func play(named name: String) {
        // Only names from the folder: a settings file must not point elsewhere.
        guard names.contains(name),
              let sound = NSSound(contentsOf: directory.appending(path: "\(name).aiff"), byReference: true)
        else { return }
        playing?.stop()
        playing = sound
        sound.play()
    }
}
