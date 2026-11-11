// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import AppKit
import Observation
import PerekeyInput
import SwiftUI

/// «Typing recording (dev)» in the menu of a build with `PEREKEY_RECORD`
/// (CONTRIBUTING.md, «Recording typing for the measure»). Off at every launch:
/// the user switches it on by hand. While it is on, the menu bar item says
/// what the recorder is doing, whatever its settings (`RecordingBadge`): the
/// engine's word, not the position of the switch.
///
/// Never in a release: `scripts/check-no-recorder.sh` checks the binary.
@MainActor
@Observable
final class SessionRecording {
    private(set) var isOn = false
    /// What the recorder is doing, as the engine says; nil while it is off.
    /// Right after the switch it is waiting: the engine has not spoken yet.
    private(set) var status: TypingRecordingStatus?
    /// Apps the user added to the password managers (`RecordingBuffer.passwordManagers`).
    private(set) var ownExcluded: Set<String>

    /// The status changed, or the recording went off (nil).
    @ObservationIgnored var onChange: ((TypingRecordingStatus?) -> Void)?
    @ObservationIgnored let recorder: SessionRecorder
    @ObservationIgnored private let input: InputController
    @ObservationIgnored private let preferences: RecordingPreferences

    init(input: InputController, defaults: UserDefaults = .standard) {
        let info = Bundle.main.infoDictionary
        recorder = SessionRecorder(perekey: info?["CFBundleShortVersionString"] as? String ?? "dev",
                                   build: info?["CFBundleVersion"] as? String ?? "0")
        self.input = input
        preferences = RecordingPreferences(defaults: defaults)
        ownExcluded = preferences.ownExcluded
        // Recordings older than 30 days go at launch.
        recorder.removeExpired()
        input.onRecordingStatus = { [weak self] in self?.engineSaid($0) }
    }

    /// The engine's word about the recorder. Late words of a recording that
    /// is off are dropped.
    private func engineSaid(_ new: TypingRecordingStatus?) {
        guard isOn == (new != nil), new != status else { return }
        status = new
        onChange?(new)
    }

    /// Stops the recording and returns after its file is written and closed:
    /// for the quit of the app.
    func finish() {
        input.finishRecording()
    }

    /// Every app nothing is recorded in.
    var excludedApps: Set<String> { RecordingBuffer.passwordManagers.union(ownExcluded) }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        status = on ? .waiting : nil
        if on {
            input.startRecording(recorder, excludedApps: excludedApps)
        } else {
            input.stopRecording()
        }
        onChange?(status)
    }

    /// A password manager is always excluded; any other app as the user says.
    func isExcluded(_ bundleID: String) -> Bool { excludedApps.contains(bundleID) }
    func canChange(_ bundleID: String) -> Bool { !RecordingBuffer.passwordManagers.contains(bundleID) }

    func setExcluded(_ bundleID: String, _ excluded: Bool) {
        guard canChange(bundleID) else { return }
        if excluded { ownExcluded.insert(bundleID) } else { ownExcluded.remove(bundleID) }
        preferences.ownExcluded = ownExcluded
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

/// A mark and «rec» left of the capsule while the typing recording is on. The
/// menu bar item stays visible then, whatever its setting. The mark is the
/// recorder's state: a red dot while typing goes to the file, a grey pause
/// while it waits (a password field, an unknown focus, a busy disk, a moment
/// before a quiet point), a warning when the file could not be written.
struct RecordingBadge: View {
    /// The second marker `scripts/check-no-recorder.sh` looks for, on the side of
    /// the app: a build that has this badge has the recorder. It is the badge's
    /// accessibility identifier, so the compiler keeps it.
    static let marker = "app.perekey.recording-badge"

    let status: TypingRecordingStatus

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint)
            Text("rec")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .accessibilityIdentifier(Self.marker)
    }

    private var symbol: String {
        switch status {
        case .recording: "record.circle.fill"
        case .waiting: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .recording: .red
        case .waiting: .secondary
        case .failed: .orange
        }
    }
}
#endif
