// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
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

    private let engineIsRunning: @MainActor () -> Bool
    private let demoActive: @MainActor (Bool) -> Void

    init(store: SettingsStore, sources: InputSources, engineIsRunning: @escaping @MainActor () -> Bool = { false },
         demoActive: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.engineIsRunning = engineIsRunning
        self.demoActive = demoActive
        self.store = store
        self.sources = sources
    }

    /// Opens the window on first launch only.
    func showIfFirstLaunch() {
        if !store.settings.onboardingDone { show() }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let model = OnboardingModel(store: store, sources: sources)
        model.engineIsRunning = engineIsRunning
        model.demoActive = demoActive
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closing the window counts as done: it must not come back on every launch.
    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window = nil
        store.update { $0.onboardingDone = true }
    }
}
