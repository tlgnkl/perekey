// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyInput
import SwiftUI

@main
struct PerekeyApp: App {
    // A plain `let`: the App value is created once, and the `@State` macro plugin
    // is missing from Command Line Tools.
    private let inputSources = InputSources()
    private let store: SettingsStore
    private let recording: ShortcutRecording
    private let onboarding: OnboardingController
    private let pause = PauseState()
    private let launchAtLogin = LaunchAtLogin()
    private let pauseSources: PauseSources
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
        let store = SettingsStore()
        self.store = store
        recording = ShortcutRecording(store: store)
        pauseSources = PauseSources(pause: pause)
        let onboarding = OnboardingController(store: store, sources: inputSources)
        self.onboarding = onboarding
        Task { @MainActor in onboarding.showIfFirstLaunch() }
        // Menu bar only, no Dock icon. The bundled Info.plist sets LSUIElement too;
        // this keeps `swift run` behaving the same way.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(sources: inputSources, store: store, pause: pause, launch: launchAtLogin,
                        onShowOnboarding: { onboarding.show() })
        } label: {
            MenuBarLabel(sources: inputSources, store: store, pause: pause)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, recording: recording)
        }
    }
}

/// Removes Perekey's Caps Lock remap on quit: it would outlive the app until logout.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        CapsLockRemapper.apply(.untouched)
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
