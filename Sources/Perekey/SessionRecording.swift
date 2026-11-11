// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import AppKit
import Observation
import PerekeyInput
import SwiftUI

/// «Typing recording (dev)» in the menu of a build with `PEREKEY_RECORD`
/// (CONTRIBUTING.md, «Recording typing for the measure»). Off by default. The
/// choice outlives a relaunch, and while the recording runs the menu bar item
/// says so, whatever its settings (`RecordingBadge`).
///
/// Never in a release: `scripts/check-no-recorder.sh` checks the binary.
@MainActor
@Observable
final class SessionRecording {
    static let onKey = "sessionRecording"
    static let excludedKey = "sessionRecordingExcludedApps"

    private(set) var isOn: Bool
    /// Apps the user added to the password managers (`RecordingBuffer.passwordManagers`).
    private(set) var ownExcluded: Set<String>

    /// The recording was turned on or off.
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored let recorder: SessionRecorder
    @ObservationIgnored private let input: InputController
    @ObservationIgnored private let defaults: UserDefaults

    init(input: InputController, defaults: UserDefaults = .standard) {
        let info = Bundle.main.infoDictionary
        recorder = SessionRecorder(perekey: info?["CFBundleShortVersionString"] as? String ?? "dev",
                                   build: info?["CFBundleVersion"] as? String ?? "0")
        self.input = input
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.onKey)
        ownExcluded = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
        // Recordings older than 30 days go at launch.
        recorder.removeExpired()
        if isOn { input.startRecording(recorder, excludedApps: excludedApps) }
    }

    /// Every app nothing is recorded in.
    var excludedApps: Set<String> { RecordingBuffer.passwordManagers.union(ownExcluded) }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.onKey)
        if on {
            input.startRecording(recorder, excludedApps: excludedApps)
        } else {
            input.stopRecording()
        }
        onChange?(on)
    }

    /// A password manager is always excluded; any other app as the user says.
    func isExcluded(_ bundleID: String) -> Bool { excludedApps.contains(bundleID) }
    func canChange(_ bundleID: String) -> Bool { !RecordingBuffer.passwordManagers.contains(bundleID) }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        guard canChange(bundleID) else { return }
        if excluded { ownExcluded.insert(bundleID) } else { ownExcluded.remove(bundleID) }
        defaults.set(ownExcluded.sorted(), forKey: Self.excludedKey)
        input.setRecordingExclusions(excludedApps)
    }

    /// Asks, then removes every recording. A recording that runs goes on in a new file.
    func confirmErase() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Erase all typing recordings?")
        alert.informativeText = String(localized: "The files of the typing recording are removed from this Mac. This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Erase"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        input.eraseRecordings(recorder)
    }

    func showInFinder() {
        try? recorder.folder.prepare()
        NSWorkspace.shared.open(recorder.folder.directory)
    }
}

/// ● and «rec» left of the capsule while the typing recording runs. The
/// menu bar item stays visible then, whatever its setting.
struct RecordingBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.red)
            Text("rec")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .accessibilityHidden(true)
    }
}
#endif
