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
    /// `PEREKEY_SNAPSHOT_GLASS=1` draws Liquid Glass (if the SDK has it); the default is the fallback look.
    private static let liquidGlass = ProcessInfo.processInfo.environment["PEREKEY_SNAPSHOT_GLASS"] == "1"

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
        renderSettingsWindow(in: directory)
        renderApps(in: directory)
        renderSites(in: directory)
        renderWordsAndGeneral(in: directory)
        renderOnboarding(in: directory)
        renderMenuBar(into: directory)
        renderHint(in: directory)
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
                let store = SettingsStore(file: file)
                let pause = PauseState(frozen: menu.pause, now: now)
                let appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
                appModes.freeze(frontmost: FrontApp(bundleID: "com.apple.Terminal", name: "Terminal", isGame: false))
                let view = MenuContent(sources: sources, store: store, pause: pause, launch: menu.launch, appModes: appModes)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 318, height: 520),
                       to: directory.appending(path: "menu-\(menu.name)-\(suffix).png"))
            }
        }
    }

    /// The whole Settings window, every section, light and dark.
    private static func renderSettingsWindow(in directory: URL) {
        let sources = InputSources()
        var settings = AppSettings(words: {
            var words = WordExceptions(mine: ["перекей", "kubectl"])
            words.learned = [LearnedWord(word: "дедлайн", learnedAt: Date().addingTimeInterval(-86_400 * 2).timeIntervalSince1970)]
            return words
        }())
        settings.apps["com.apple.Notes"] = AppRule(mode: .auto, rememberLastLayout: true)
        settings.apps["com.apple.Terminal"] = AppRule(mode: .manualOnly)
        settings.apps["com.apple.Chess"] = AppRule(mode: .off)
        let file = SettingsFile(url: directory.appending(path: "window.json"))
        try? file.save(settings)
        let store = SettingsStore(file: file)
        let recording = ShortcutRecording(store: store)
        for dark in [false, true] {
            for section in SettingsSection.allCases {
                let view = SettingsView(store: store, recording: recording, sources: sources, initial: section, windowBackground: false)
                render(view, dark: dark, size: CGSize(width: 840, height: 640),
                       to: directory.appending(path: "settings-\(section)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The Apps pane (light and dark, filtered) and the picker.
    private static func renderApps(in directory: URL) {
        let sources = InputSources()
        let file = SettingsFile(url: directory.appending(path: "apps.json"))
        var settings = AppSettings()
        settings.apps["com.apple.Notes"] = AppRule(mode: .auto, rememberLastLayout: true)
        settings.apps["com.apple.Safari"] = AppRule(mode: .auto, defaultLayout: sources.layouts.last?.id)
        settings.apps["com.apple.Terminal"] = AppRule(mode: .auto)
        settings.apps["com.apple.Chess"] = AppRule(mode: .off)
        try? file.save(settings)
        let store = SettingsStore(file: file)
        func model() -> AppsPaneModel {
            let url = URL(fileURLWithPath: "/System/Applications")
            let ids = ["com.apple.Terminal": "Terminal", "com.apple.dt.Xcode": "Xcode", "com.microsoft.VSCode": "Visual Studio Code"]
            return AppsPaneModel(builtIns: ids.map {
                AppCandidate(bundleID: $0.key, name: $0.value, url: AppInfo.url(bundleID: $0.key) ?? url, isRunning: false)
            })
        }
        let size = CGSize(width: 560, height: 560)
        for dark in [false, true] {
            render(AppsPane(store: store, sources: sources, model: model()).background(Color(nsColor: .windowBackgroundColor)),
                   dark: dark, size: size, to: directory.appending(path: "apps-\(dark ? "dark" : "light").png"))
        }
        let filtered = model()
        filtered.modeFilter = .manualOnly
        render(AppsPane(store: store, sources: sources, model: filtered).background(Color(nsColor: .windowBackgroundColor)),
               dark: false, size: size, to: directory.appending(path: "apps-filtered.png"))
        for (name, query) in [("picker", ""), ("picker-search", "ter")] {
            let picker = AppPickerModel(spotlight: false)
            picker.query = query
            picker.selection = 1
            render(AppPickerView(model: picker, existing: ["com.apple.Notes"]) { _ in }
                .background(Color(nsColor: .windowBackgroundColor)),
                dark: false, size: CGSize(width: 360, height: 360), to: directory.appending(path: "apps-\(name).png"))
        }
    }

    /// The Sites pane: filled (light and dark), empty, and with an invalid draft.
    private static func renderSites(in directory: URL) {
        let sources = InputSources()
        let file = SettingsFile(url: directory.appending(path: "sites.json"))
        var settings = AppSettings()
        settings.sites["github.com"] = SiteRule(defaultLayout: sources.layouts.first?.id)
        settings.sites["habr.com"] = SiteRule(defaultLayout: sources.layouts.last?.id)
        settings.sites["mail.example.org"] = SiteRule(rememberLastLayout: true)
        try? file.save(settings)
        let store = SettingsStore(file: file)
        let size = CGSize(width: 560, height: 560)
        for dark in [false, true] {
            render(SitesPane(store: store, sources: sources).background(Color(nsColor: .windowBackgroundColor)),
                   dark: dark, size: size, to: directory.appending(path: "sites-\(dark ? "dark" : "light").png"))
        }
        let emptyStore = SettingsStore(file: SettingsFile(url: directory.appending(path: "sites-empty.json")))
        render(SitesPane(store: emptyStore, sources: sources, initialDraft: "not a host!")
            .background(Color(nsColor: .windowBackgroundColor)),
            dark: false, size: size, to: directory.appending(path: "sites-empty.png"))
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

    /// The caret hint in both states, light and dark.
    private static func renderHint(in directory: URL) {
        let states: [(String, HintContent)] = [
            ("corrected", .corrected(original: "ghbdtn", replacement: "привет")),
            ("learned", .learned(word: "дедлайн")),
        ]
        for (name, content) in states {
            for dark in [false, true] {
                let model = HintModel(content: content, visible: true)
                render(HintView(model: model) {}, dark: dark, size: CGSize(width: 320, height: 90),
                       to: directory.appending(path: "hint-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
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
            render(OnboardingView(model: model, heroPhase: 4.5), dark: false, size: size,
                   to: directory.appending(path: "onboarding-\(step.rawValue + 1)-\(step).png"))
        }
        let solved = OnboardingModel(store: store, sources: sources, step: .demo, live: false)
        solved.fakeSolvedDemo()
        render(OnboardingView(model: solved).background(Color(nsColor: .windowBackgroundColor)), dark: true, size: size,
               to: directory.appending(path: "onboarding-4-demo-solved-dark.png"))
    }

    private static func render(_ view: some View, dark: Bool, size: NSSize = NSSize(width: 560, height: 640), to url: URL) {
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.pkLiquidGlass, liquidGlass))
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
