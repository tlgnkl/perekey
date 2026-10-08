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
            render(view, dark: item.dark, size: CGSize(width: 560, height: 640), to: directory.appending(path: "\(item.name).png"))
        }
        renderWordsAndGeneral(in: directory)
        renderOnboarding(in: directory)
        renderMenuBar(into: directory)
        exit(0)
    }

    /// The capsule in every state, through the same `NSImage` path as the menu bar
    /// (on a strip tinted like the bar), and the menu content in a few states.
    private static func renderMenuBar(into directory: URL) {
        let now = Date()
        let sources = InputSources()
        let code = sources.currentLayout.map(sources.indicator(of:)) ?? "EN"
        func set(_ build: (inout PauseSet) -> Void) -> PauseSet {
            var value = PauseSet()
            build(&value)
            return value
        }
        let states: [(name: String, struck: Bool, pause: PauseSet)] = [
            ("normal", false, PauseSet()),
            ("autoswitch-off", true, PauseSet()),
            ("timed", false, set { $0.pause(until: now.addingTimeInterval(59 * 60 - 30)) }),
            ("secure", false, set { $0.setSecureInput(true, owner: "1Password") }),
            ("password", false, set { $0.setPasswordField(true) }),
            ("appoff", false, set { $0.setAppOff(app: "Terminal") }),
        ]
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let bar = dark ? Color(white: 0.16) : Color(white: 0.92)
            for state in states {
                let model = CapsuleModel(code: code, struck: state.struck, reason: state.pause.top(at: now), now: now)
                let image = CapsuleImage.make(model, dark: dark)
                let view = Image(nsImage: image).padding(.horizontal, 16).frame(height: 28).background(bar)
                render(view.fixedSize(), dark: dark, size: CGSize(width: 220, height: 28),
                       to: directory.appending(path: "capsule-\(state.name)-\(suffix).png"))
            }
            let menus: [(name: String, pause: PauseSet, launch: LaunchAtLogin, autoswitch: Bool)] = [
                ("normal", PauseSet(), LaunchAtLogin(previewStatus: .notFound), true),
                ("timed", states[2].pause, LaunchAtLogin(previewStatus: .requiresApproval), true),
                ("secure", states[3].pause, LaunchAtLogin(previewStatus: .enabled), false),
                ("appoff", states[5].pause, LaunchAtLogin(previewStatus: .notFound, error: "Operation not permitted"), true),
            ]
            for menu in menus {
                let file = SettingsFile(url: directory.appending(path: "menu-\(menu.name).json"))
                try? file.save(AppSettings(autoswitch: menu.autoswitch))
                let view = MenuContent(sources: sources, store: SettingsStore(file: file),
                                       pause: PauseState(frozen: menu.pause, now: now), launch: menu.launch)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 318, height: 520),
                       to: directory.appending(path: "menu-\(menu.name)-\(suffix).png"))
            }
        }
    }

    /// The Words pane with sample words (and a frequent-word warning), and the General pane.
    private static func renderWordsAndGeneral(in directory: URL) {
        var words = WordExceptions(mine: ["перекей", "kubectl", "ё-моё"])
        words.learned = [
            LearnedWord(word: "дедлайн", learnedAt: Date().addingTimeInterval(-86_400 * 2).timeIntervalSince1970),
            LearnedWord(word: "ghbdtn", learnedAt: Date().addingTimeInterval(-86_400 * 20).timeIntervalSince1970),
        ]
        let size = CGSize(width: 560, height: 560)
        for (name, sample, dark) in [("words-light", words, false), ("words-empty-dark", WordExceptions(), true)] {
            let file = SettingsFile(url: directory.appending(path: "\(name).json"))
            try? file.save(AppSettings(words: sample))
            let view = WordsPane(store: SettingsStore(file: file)).frame(width: size.width, height: size.height)
            render(view, dark: dark, size: size, to: directory.appending(path: "\(name).png"))
        }
        let general = SettingsStore(file: SettingsFile(url: directory.appending(path: "general.json")))
        render(GeneralPane(store: general).frame(width: size.width, height: 300), dark: false,
               size: CGSize(width: size.width, height: 300), to: directory.appending(path: "general-light.png"))
        let store = SettingsStore(file: SettingsFile(url: directory.appending(path: "words-warn.json")))
        let warn = WordsPane(store: store, isFrequent: { _ in true }, initialDraft: "привет")
        render(warn.frame(width: size.width, height: size.height), dark: false, size: size,
               to: directory.appending(path: "words-warning-light.png"))
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
