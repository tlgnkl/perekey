// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore

/// An alert for what Finder's «Open With» could not do: a refusal says why, and
/// offers Settings → Voice when turning voice on would help.
@MainActor
enum OpenAlert {
    static func show(title: String, reason: String, openSettings: (() -> Void)?, settingsTitle: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = reason
        alert.addButton(withTitle: openSettings == nil ? String(localized: "OK") : settingsTitle)
        if openSettings != nil { alert.addButton(withTitle: String(localized: "Cancel")) }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openSettings?() }
    }
}

#if PEREKEY_VOICE
/// Audio and video from Finder, for the transcription queue. On a cold launch
/// AppKit hands the files over before the queue exists: they wait for it, and
/// are refused with a reason if it does not come (`FileOpenDecision`).
@MainActor
final class OpenedFiles {
    private let files: FileTranscription
    private let availability: () -> VoiceAvailability
    private let openVoiceSettings: () -> Void
    private var pending: [URL] = []
    private var deadline: Task<Void, Never>?

    init(files: FileTranscription, availability: @escaping () -> VoiceAvailability, openVoiceSettings: @escaping () -> Void) {
        self.files = files
        self.availability = availability
        self.openVoiceSettings = openVoiceSettings
    }

    func open(_ urls: [URL]) {
        pending += urls.filter(FileTranscription.accepts)
        if pending.isEmpty { return refuse(.notMedia) }
        resolve()
    }

    /// The queue came or went, or voice changed: what waits goes in, stays or is refused.
    func queueChanged() {
        if !pending.isEmpty { resolve() }
    }

    private func resolve(late: Bool = false) {
        switch FileOpenDecision.decide(hasMedia: !pending.isEmpty, voice: availability(),
                                       queueReady: files.queue != nil, waitedTooLong: late) {
        case .enqueue:
            let urls = pending
            finish()
            files.transcribe(urls)
        case .hold:
            guard deadline == nil else { return }
            deadline = Task { [weak self] in
                try? await Task.sleep(for: FileOpenDecision.holdLimit)
                guard !Task.isCancelled else { return }
                self?.deadline = nil
                self?.resolve(late: true)
            }
        case .refuse(let reason):
            finish()
            refuse(reason)
        }
    }

    private func finish() {
        pending = []
        deadline?.cancel()
        deadline = nil
    }

    private func refuse(_ reason: FileOpenDecision.Refusal) {
        let text: String
        switch reason {
        case .notMedia: text = voiceString("Perekey transcribes audio and video files. This one is neither.")
        case .voiceOff: text = voiceString("Voice input is off. Turn it on in Settings → Voice to transcribe files.")
        case .voiceUnavailable: text = voiceString("Voice input is not available on this Mac, or your administrator turned it off.")
        case .notReady: text = voiceString("Voice input did not start in time. Try again in a moment.")
        }
        OpenAlert.show(title: voiceString("The file was not transcribed"), reason: text,
                       openSettings: reason.settingsCanHelp ? openVoiceSettings : nil,
                       settingsTitle: voiceString("Open Settings → Voice"))
    }
}
#endif
