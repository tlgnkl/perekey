// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore

/// An alert for what Finder's «Open With» could not do: a refusal says why, and
/// offers Settings → Voice when a change there would help. It never shows during
/// launch (`runModal` would hold `applicationDidFinishLaunching`) and never over
/// onboarding or the voice intro: then it is skipped, since both lead to voice setup.
/// One alert at a time: events that come while it is open are dropped.
@MainActor
enum OpenAlert {
    private struct Request {
        var title: String
        var reason: String
        var openSettings: (() -> Void)?
        var settingsTitle: String
    }

    static var onScreen: () -> Bool = { false }
    private static var hasLaunched = false
    private static var waiting: Request?
    private static var isShowing = false

    static func show(title: String, reason: String, openSettings: (() -> Void)?, settingsTitle: String) {
        guard !isShowing else { return }
        waiting = Request(title: title, reason: reason, openSettings: openSettings, settingsTitle: settingsTitle)
        if hasLaunched { schedule() }
    }

    /// Called at the end of `applicationDidFinishLaunching`.
    static func launched() {
        hasLaunched = true
        if waiting != nil { schedule() }
    }

    private static func schedule() {
        // Next turn of the run loop: the launch, and the windows it opens, are done.
        Task { @MainActor in
            guard let request = waiting, !isShowing else { return }
            waiting = nil
            guard !onScreen() else { return }
            isShowing = true
            defer { isShowing = false }
            let alert = NSAlert()
            alert.messageText = request.title
            alert.informativeText = request.reason
            alert.addButton(withTitle: request.openSettings == nil ? String(localized: "OK") : request.settingsTitle)
            if request.openSettings != nil { alert.addButton(withTitle: String(localized: "Cancel")) }
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { request.openSettings?() }
        }
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
        let media = urls.filter(FileTranscription.accepts)
        // A file that is no media is refused even while others wait.
        if media.isEmpty { return refuse(.notMedia) }
        pending += media
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
        case .noShortcut: text = voiceString("Voice input has no shortcut. Set one in Settings → Voice to transcribe files.")
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
