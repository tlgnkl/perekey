// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// The entry point. Plain AppKit, not a SwiftUI `App`: every window is an
/// `NSWindow` Perekey owns, and a SwiftUI `Settings` scene cannot serve a menu bar
/// app. Its `showSettingsWindow:` opens nothing since macOS 14, and the scene
/// opens itself at launch.
@main
@MainActor
enum PerekeyMain {
    static func main() {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only, no Dock icon. The bundled Info.plist sets LSUIElement too;
        // this keeps `swift run` behaving the same way.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Builds the app and keeps it alive.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let inputSources = InputSources()
    private let store: SettingsStore
    private let onboarding: OnboardingController
    private let pause = PauseState()
    private let launchAtLogin = LaunchAtLogin()
    private let updates: Updates
    private let input: InputController
    private let shell: MenuBarShell
    private let usage: UsageRecorder

    override init() {
        let store = SettingsStore()
        self.store = store
        let recording = ShortcutRecording(store: store)
        let updates = Updates(store: store)
        self.updates = updates
        let input = InputController(sources: inputSources, store: store, pause: pause)
        self.input = input
        let onboarding = OnboardingController(store: store, sources: inputSources, recording: recording,
                                              engineIsRunning: { input.tapState == .running },
                                              demoActive: { input.appModes.onboardingDemo = $0 })
        self.onboarding = onboarding
        let recents = RecentCorrections()
        let usage = UsageRecorder { [store] in store.settings.statistics }
        self.usage = usage
        input.onCorrection = { recents.record($0); usage.recordCorrection($0.kind) }
        input.onCorrectionUndone = { recents.undone(seq: $0); usage.recordUndo() }
        input.onManualRetype = { usage.recordManualRetype() }
        input.onAccessLost = { onboarding.show(at: .access) }
        let sources = inputSources
        let settings = SettingsWindow(recording: recording) {
            SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                         languages: input.languages)
        }
        shell = MenuBarShell(sources: inputSources, store: store, pause: pause, launch: launchAtLogin,
                             input: input, recents: recents, usage: usage, onboarding: onboarding, updates: updates,
                             settings: settings)
        super.init()
        ExternalControl.shared = ExternalControl(store: store, pause: pause, appModes: input.appModes, sources: inputSources)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        onboarding.showIfNeeded()
        // After launch, so the status bar exists.
        shell.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Counters reach the disk at most every few seconds, and here at quit.
        usage.flush()
        // The Caps Lock remap would outlive the app until logout.
        CapsLockRemapper.apply(.untouched)
    }

    /// `perekey://` links (see `ControlCommand`).
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalControl.shared?.open(urls)
    }

    /// The menu bar never shows (LSUIElement), but its key equivalents work in
    /// Perekey's windows: ⌘C, ⌘V and ⌘Z in text fields, ⌘W, ⌘Q. Nobody sees
    /// the titles, so they stay in English.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        _ = add("Perekey", [
            item("Hide Perekey", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Quit Perekey", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        NSApp.windowsMenu = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
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
         recents: RecentCorrections, usage: UsageRecorder, onboarding: OnboardingController, updates: Updates,
         settings: SettingsWindow)
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
                openSettings: { menu.close(); settings.show() },
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

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
