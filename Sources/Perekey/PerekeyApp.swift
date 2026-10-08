// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
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
    private let updates: Updates
    private let input: InputController
    private let shell: MenuBarShell
    private let usage: UsageRecorder
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
        let store = SettingsStore()
        self.store = store
        recording = ShortcutRecording(store: store)
        updates = Updates(store: store)
        let input = InputController(sources: inputSources, store: store, pause: pause)
        self.input = input
        let onboarding = OnboardingController(store: store, sources: inputSources,
                                              engineIsRunning: { input.tapState == .running },
                                              demoActive: { input.appModes.onboardingDemo = $0 })
        self.onboarding = onboarding
        let recents = RecentCorrections()
        let usage = UsageRecorder { [store] in store.settings.statistics }
        self.usage = usage
        input.onCorrection = { recents.record($0); usage.recordCorrection($0.kind) }
        input.onCorrectionUndone = { recents.undone(seq: $0); usage.recordUndo() }
        input.onManualRetype = { usage.recordManualRetype() }
        // Counters reach the disk at most every few seconds, and here at quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { usage.flush() }
        }
        let shell = MenuBarShell(sources: inputSources, store: store, pause: pause, launch: launchAtLogin,
                             input: input, recents: recents, usage: usage, onboarding: onboarding, updates: updates)
        self.shell = shell
        Task { @MainActor in
            onboarding.showIfFirstLaunch()
            // After launch, so the status bar exists.
            shell.start()
        }
        ExternalControl.shared = ExternalControl(store: store, pause: pause, appModes: input.appModes, sources: inputSources)
        // Menu bar only, no Dock icon. The bundled Info.plist sets LSUIElement too;
        // this keeps `swift run` behaving the same way.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            SettingsView(store: store, recording: recording, sources: inputSources, updates: updates, usage: usage,
                         languages: input.languages)
        }
    }
}

/// The menu bar part: the live capsule and its menu panel, plus the windows the
/// menu opens. A class, because the App value cannot hold changing state.
@MainActor
final class MenuBarShell {
    private let sources: InputSources
    private let store: SettingsStore
    private let recents: RecentCorrections
    private let onboarding: OnboardingController
    private let menu: MenuPanelController
    private let reportWindow = ReportWordWindow()
    private let pause: PauseState
    private var statusItem: StatusItemController?

    init(sources: InputSources, store: SettingsStore, pause: PauseState, launch: LaunchAtLogin, input: InputController,
         recents: RecentCorrections, usage: UsageRecorder, onboarding: OnboardingController, updates: Updates)
    {
        self.sources = sources
        self.store = store
        self.pause = pause
        self.recents = recents
        self.onboarding = onboarding
        let reportWindow = reportWindow
        menu = MenuPanelController(
            sources: sources, store: store, pause: pause, launch: launch, appModes: input.appModes,
            recents: recents, usage: usage, updates: updates
        ) { menu in
            MenuActions(
                openSettings: {
                    menu.close()
                    // A menu bar app has no Dock icon: activate first, then ask for the window.
                    NSApp.activate()
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    SettingsFront.raise()
                },
                showOnboarding: { menu.close(); onboarding.show() },
                showAbout: {
                    menu.close()
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                },
                quit: { NSApplication.shared.terminate(nil) },
                report: { word, reason in
                    menu.close()
                    reportWindow.show(word: word, reason: reason, layouts: sources.layouts.map { FalseSwitchReport.layoutName($0.id) })
                }
            )
        }
    }

    func start() {
        guard statusItem == nil else { return }
        statusItem = StatusItemController(sources: sources, store: store, pause: pause, recents: recents, menu: menu)
    }
}

/// "Report a word" from the menu: the form in its own small window.
@MainActor
final class ReportWordWindow {
    private var window: NSWindow?

    func show(word: String, reason: String = "", layouts: [String]) {
        window?.close()
        let sheet = ReportWordSheet(initialWord: word, reason: reason, layouts: layouts, version: ReportContext.version, onOpen: { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.window?.close()
        }, onCancel: { [weak self] in self?.window?.close() })
        let host = NSHostingView(rootView: sheet)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "Report a word")
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Removes Perekey's Caps Lock remap on quit: it would outlive the app until logout.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        CapsLockRemapper.apply(.untouched)
    }

    /// `perekey://` links (see `ControlCommand`).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ExternalControl.shared?.open(urls) }
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
