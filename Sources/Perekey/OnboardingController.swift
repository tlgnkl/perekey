// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import PerekeyInput
import SwiftUI

/// Owns the onboarding window. A plain `NSWindow` instead of a SwiftUI scene:
/// a menu bar app has no view to open a scene from at launch, and a `Window`
/// scene would open itself on every launch.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let sources: InputSources
    private var window: NSWindow?
    private var model: OnboardingModel?

    #if PEREKEY_VOICE
    /// The voice offer for a run of the window, nil when voice is not offered.
    var makeVoiceIntro: (@MainActor () -> VoiceIntroModel?)?
    #endif
    private let recording: ShortcutRecording?
    private let engineIsRunning: @MainActor () -> Bool
    private let demoActive: @MainActor (Bool) -> Void

    init(store: SettingsStore, sources: InputSources, recording: ShortcutRecording? = nil,
         engineIsRunning: @escaping @MainActor () -> Bool = { false },
         demoActive: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.recording = recording
        self.engineIsRunning = engineIsRunning
        self.demoActive = demoActive
        self.store = store
        self.sources = sources
    }

    /// Opens the window on first launch, and at the access step whenever
    /// Perekey starts without access: the engine no longer makes macOS ask.
    var isOnScreen: Bool { window?.isVisible == true }

    func showIfNeeded() {
        if !store.settings.onboardingDone {
            show()
        } else if !AXIsProcessTrusted() {
            show(at: .access)
        }
    }

    func show(at step: OnboardingModel.Step = .welcome) {
        if let window {
            // Never back: a reopen must not overwrite the step the user is on.
            if let model, model.step.rawValue < step.rawValue { model.step = step }
            bringToFront(window)
            return
        }
        let model = OnboardingModel(store: store, sources: sources, step: step)
        model.engineIsRunning = engineIsRunning
        model.demoActive = demoActive
        model.recording = recording
        #if PEREKEY_VOICE
        model.voiceIntro = makeVoiceIntro?()
        #endif
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to Perekey")
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.window?.close()
        })
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        model.window = window
        self.model = model
        self.window = window
        bringToFront(window)
    }

    /// In front even when macOS declines to activate the app: a menu bar app
    /// launched in the background gets no cooperative activation, and its window
    /// would stay under the others while Perekey does nothing.
    private func bringToFront(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
    }

    /// Closing the window counts as done: it must not come back on every launch.
    func windowWillClose(_ notification: Notification) {
        #if PEREKEY_VOICE
        // Closed at the voice step: the offer was seen, and the answer is "Not now".
        if model?.step == .voice { model?.voiceIntro?.closed() }
        model?.voiceIntro?.recording.stop()
        #endif
        model?.stop()
        model = nil
        window = nil
        store.update { $0.onboardingDone = true }
    }
}
