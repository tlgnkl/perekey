// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// Renders the settings panes to PNG files and quits, for reviewing the UI
/// without a screen: `PEREKEY_SNAPSHOT=<dir> .build/debug/Perekey`.
///
/// Draws into an offscreen window, so it needs no Screen Recording permission.
/// Uses a settings file in `<dir>`, never the user's, and only Caps Lock modes
/// that do not touch the keyboard.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PEREKEY_SNAPSHOT"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let cases: [(name: String, settings: AppSettings, dark: Bool)] = [
            ("shortcuts-standard-light", AppSettings(), false),
            ("shortcuts-separate-dark", AppSettings(hotkeys: HotkeyPreset.separateKeys.hotkeys, capsLock: .system), true),
            ("shortcuts-custom-light", {
                var settings = AppSettings()
                settings.setTrigger(.modifiers(.shift, taps: .double), for: .convertLastWord)
                settings.setTrigger(.key(keyCode: 14, modifiers: [.control, .option]), for: .selectLanguage("en"))
                return settings
            }(), false),
        ]
        for item in cases {
            let file = SettingsFile(url: directory.appending(path: "\(item.name).json"))
            try? file.save(item.settings)
            let store = SettingsStore(file: file)
            let view = ShortcutsPane(store: store, recording: ShortcutRecording(store: store))
                .frame(width: 560, height: 640)
            render(view, dark: item.dark, to: directory.appending(path: "\(item.name).png"))
        }
        renderOnboarding(in: directory)
        exit(0)
    }

    /// Each onboarding step, plus the demo as solved in dark mode.
    private static func renderOnboarding(in directory: URL) {
        let file = SettingsFile(url: directory.appending(path: "onboarding.json"))
        try? file.save(AppSettings())
        let store = SettingsStore(file: file)
        let sources = InputSources()
        let size = NSSize(width: 640, height: 580)
        for step in OnboardingModel.Step.allCases {
            let model = OnboardingModel(store: store, sources: sources, step: step, live: false)
            render(OnboardingView(model: model), dark: false, size: size,
                   to: directory.appending(path: "onboarding-\(step.rawValue + 1)-\(step).png"))
        }
        let solved = OnboardingModel(store: store, sources: sources, step: .demo, live: false)
        solved.fakeSolvedDemo()
        render(OnboardingView(model: solved).background(Color(nsColor: .windowBackgroundColor)), dark: true, size: size,
               to: directory.appending(path: "onboarding-4-demo-solved-dark.png"))
    }

    private static func render(_ view: some View, dark: Bool, size: NSSize = NSSize(width: 560, height: 640), to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
