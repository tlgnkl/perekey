// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import AppKit
import PerekeyCore
import PerekeyInput
#if PEREKEY_VOICE
import PerekeyVoice
import PerekeyVoiceCore
#endif
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
                .frame(width: 560, height: 860)
            render(view, dark: item.dark, size: CGSize(width: 560, height: 860), to: directory.appending(path: "\(item.name).png"))
        }
        renderSettingsWindow(in: directory)
        #if PEREKEY_VOICE
        renderVoice(in: directory)
        renderVoiceText(in: directory)
        renderVoiceHUD(in: directory)
        renderVoiceIntro(in: directory)
        renderModes(in: directory)
        renderTranscripts(in: directory)
        #endif
        renderApps(in: directory)
        renderSites(in: directory)
        renderWordsAndGeneral(in: directory)
        renderOnboarding(in: directory)
        renderMenuBar(into: directory)
        renderStatistics(in: directory)
        renderThreeLayouts(in: directory)
        renderCrowdedMenus(in: directory)
        renderHint(in: directory)
        renderReasons(in: directory)
        renderStrips(in: directory)
        exit(0)
    }

    /// Settings → General → «Menu bar» in its notes: the language shown twice, and not at all.
    private static func renderMenuBarSettings(into directory: URL, sources: InputSources) {
        let cases: [(name: String, settings: AppSettings, systemMenu: Bool?)] = [
            ("twice", AppSettings(), true),
            ("not-shown", { var s = AppSettings(); s.menuBarIcon = .mark; return s }(), false),
            ("never", { var s = AppSettings(); s.menuBarVisibility = .never; return s }(), true),
            ("never-voice", { var s = AppSettings(); s.menuBarVisibility = .never; return s }(), true),
        ]
        for item in cases {
            let file = SettingsFile(url: directory.appending(path: "menubar-\(item.name).json"))
            try? file.save(item.settings)
            let store = SettingsStore(file: file)
            let size = CGSize(width: 560, height: 360)
            for dark in [false, true] {
                render(MenuBarGroup(store: store, sources: sources, systemMenu: SystemInputMenu(preview: item.systemMenu),
                                 voiceIsOn: item.name.hasSuffix("voice"))
                    .padding(20).frame(width: size.width, height: size.height, alignment: .top), dark: dark, size: size,
                       to: directory.appending(path: "menubar-settings-\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The capsule in every state, through the same `NSImage` path as the menu bar
    /// (on a strip tinted like the bar), and the menu content in a few states.
    private static func renderMenuBar(into directory: URL) {
        let now = Date()
        let sources = InputSources()
        let code = sources.currentLayout.map(sources.indicator(of:)) ?? "EN"
        let preview = MenuBarPreview(sources: sources)
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
        renderMenuBarSettings(into: directory, sources: sources)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let bar = dark ? Color(white: 0.16) : Color(white: 0.92)
            for state in states {
                let model = CapsuleModel(code: code, struck: state.struck, reason: state.pause.top(at: now), now: now)
                let view = CapsuleView(model: model, dark: dark).padding(.horizontal, 16).frame(height: 28).background(bar)
                render(view.fixedSize(), dark: dark, size: CGSize(width: 220, height: 28),
                       to: directory.appending(path: "capsule-\(state.name)-\(suffix).png"))
                // The other looks, drawn in the bar's foreground.
                for style in [MenuBarIconStyle.letters, .system, .mark] {
                    let glyph = MenuBarGlyph(style: style, model: model, icon: preview.icon)
                        .padding(.horizontal, 16).frame(height: 28).background(bar)
                        .foregroundStyle(dark ? Color.white : Color.black)
                    render(glyph.fixedSize(), dark: dark, size: CGSize(width: 220, height: 28),
                           to: directory.appending(path: "menubar-\(style.rawValue)-\(state.name)-\(suffix).png"))
                }
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
                let updates = Updates(store: store, preview: ManagedSettings(), configured: true, lastCheck: nil,
                                      pendingVersion: menu.name == "normal" ? "1.2" : nil)
                var log = CorrectionLog()
                if menu.name != "appoff" {
                    let en = sources.layouts.first?.id ?? "en", ru = sources.layouts.last?.id ?? "ru"
                    var layout = Correction(seq: 1, original: "ghbdtn", replacement: "привет", source: en, target: ru)
                    layout.decision = Classifier.Decision(verdict: .switch(to: ru), score: 38.4, reason: .compared,
                                                          language: "ru", margin: 10, typedForm: .unknown,
                                                          otherForm: .known, typedLanguage: "en", otherLanguage: "ru")
                    log.record(layout, at: now)
                    log.record(Correction(seq: 2, original: "мвд", replacement: "МВД", source: ru, target: ru, kind: .abbreviation), at: now)
                    log.record(Correction(seq: 3, original: "еще", replacement: "ещё", source: ru, target: ru, kind: .yo), at: now)
                    log.record(Correction(seq: 4, original: "чтото", replacement: "что-то", source: ru, target: ru, kind: .hyphen), at: now)
                    log.markUndone(seq: 2)
                }
                func menuView(explained: Int? = nil, hasAccess: Bool = true) -> some View {
                    var content = MenuContent(sources: sources, store: store, pause: pause,
                                              appModes: appModes, recents: RecentCorrections(log), updates: updates)
                    content.explainedEntry = explained
                    content.hasAccess = { hasAccess }
                    return content.background(Color(nsColor: .windowBackgroundColor))
                }
                render(menuView(), dark: dark, size: CGSize(width: 318, height: 640),
                       to: directory.appending(path: "menu-\(menu.name)-\(suffix).png"))
                if menu.name == "normal" {
                    // The newest-but-two row is the switch; its «Why?» open.
                    render(menuView(explained: 0), dark: dark, size: CGSize(width: 318, height: 720),
                           to: directory.appending(path: "menu-explained-\(suffix).png"))
                    render(menuView(hasAccess: false), dark: dark, size: CGSize(width: 318, height: 680),
                           to: directory.appending(path: "menu-noaccess-\(suffix).png"))
                }
                // «Launch at login» is a row of General now, in the states it can have.
                render(GeneralPane(store: store, updates: updates, launch: menu.launch).frame(width: 560, height: 1500),
                       dark: dark, size: CGSize(width: 560, height: 1500),
                       to: directory.appending(path: "general-launch-\(menu.name)-\(suffix).png"))
            }
        }
    }

    /// The whole Settings window, every section, light and dark.
    private static func renderSettingsWindow(in directory: URL) {
        let sources = InputSources()
        var settings = AppSettings(words: {
            var words = WordRules(mine: ["перекей", "kubectl"])
            words.learned = [LearnedWord(word: "дедлайн", learnedAt: Date().addingTimeInterval(-86_400 * 2).timeIntervalSince1970)]
            return words
        }())
        settings.apps["com.apple.Notes"] = AppRule(mode: .auto, rememberLastLayout: true)
        settings.apps["com.apple.Terminal"] = AppRule(mode: .manualOnly)
        settings.apps["com.apple.Chess"] = AppRule(mode: .off)
        settings.statistics = true
        let usage = sampleUsage(in: directory, name: "window")
        let file = SettingsFile(url: directory.appending(path: "window.json"))
        try? file.save(settings)
        let store = SettingsStore(file: file)
        let recording = ShortcutRecording(store: store)
        let languages = LanguageStatsStore(file: nil)
        languages.record(LanguageTally(app: "com.apple.Safari", site: nil, words: ["ru": 240, "en": 40]))
        for dark in [false, true] {
            for section in SettingsSection.allCases {
                let updates = Updates(store: store, preview: ManagedSettings(), configured: true,
                                      lastCheck: Date().addingTimeInterval(-3_600 * 5))
                var view = SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                                        languages: languages, initial: section)
                #if PEREKEY_VOICE
                view.voiceController = voicePreview(in: directory, name: "window")
                view.voiceModes = modesPreview()
                #endif
                render(view, dark: dark, size: CGSize(width: 840, height: 640),
                       to: directory.appending(path: "settings-\(section)-\(dark ? "dark" : "light").png"))
            }
            // The search: sections without a match dim, the others count their matches.
            for (name, query) in [("match", "correct"), ("none", "qqzx")] {
                let updates = Updates(store: store, preview: ManagedSettings(), configured: true,
                                      lastCheck: Date().addingTimeInterval(-3_600 * 5))
                let view = SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                                        languages: languages, initial: .general, searchQuery: query)
                render(view, dark: dark, size: CGSize(width: 840, height: 640),
                       to: directory.appending(path: "settings-search-\(name)-\(dark ? "dark" : "light").png"))
            }
            // No access: the banner above the panes.
            let updates = Updates(store: store, preview: ManagedSettings(), configured: true,
                                  lastCheck: Date().addingTimeInterval(-3_600 * 5))
            var banner = SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                                      languages: languages, initial: .general)
            banner.hasAccess = { false }
            render(banner, dark: dark, size: CGSize(width: 840, height: 640),
                   to: directory.appending(path: "settings-noaccess-\(dark ? "dark" : "light").png"))
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
        // Safari has a rule and is mostly Russian; Mail has no rule, only counts.
        let languages = LanguageStatsStore(file: nil)
        languages.record(LanguageTally(app: "com.apple.Safari", site: nil, words: ["ru": 240, "en": 40]))
        languages.record(LanguageTally(app: "com.apple.mail", site: nil, words: ["en": 300, "ru": 10]))
        let size = CGSize(width: 560, height: 560)
        for dark in [false, true] {
            render(AppsPane(store: store, sources: sources, languages: languages, model: model())
                .background(Color(nsColor: .windowBackgroundColor)),
                   dark: dark, size: size, to: directory.appending(path: "apps-\(dark ? "dark" : "light").png"))
        }
        #if PEREKEY_VOICE
        // «Вставка диктовки»: VS Code types, Terminal is automatic.
        let voiceFile = VoiceSettingsFile(url: directory.appending(path: "apps-voice.json"))
        try? FileManager.default.removeItem(at: voiceFile.url)
        try? voiceFile.save(VoiceSettings(isEnabled: true, insertion: ["com.microsoft.VSCode": .typing]))
        let voice = VoiceSettingsStore(file: voiceFile, managed: ManagedSettings())
        render(AppsPane(store: store, sources: sources, languages: languages, voice: voice, model: model())
            .background(Color(nsColor: .windowBackgroundColor)),
               dark: false, size: size, to: directory.appending(path: "apps-voice.png"))
        #endif
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

    /// ABC, Russian and Ukrainian-PC, whatever this Mac has enabled: the maps
    /// carry no keys, which no surface here reads.
    private static func threeLayouts() -> InputSources {
        let layouts = [
            LayoutMap(id: "com.apple.keylayout.ABC", language: "en", table: [:]),
            LayoutMap(id: "com.apple.keylayout.Russian", language: "ru", table: [:]),
            LayoutMap(id: "com.apple.keylayout.Ukrainian-PC", language: "uk", table: [:]),
        ]
        return InputSources(preview: layouts, current: layouts[0].id, names: [
            layouts[0].id: "ABC", layouts[1].id: "Russian", layouts[2].id: "Ukrainian - PC",
        ])
    }

    /// Onboarding, Shortcuts, General and the menu with three layouts.
    private static func renderThreeLayouts(in directory: URL) {
        let sources = threeLayouts()
        let languages = LanguagePairs(layouts: sources.layouts).languages
        for (name, preset, dark) in [("shortcuts-three-light", HotkeyPreset.standard, false),
                                     ("shortcuts-three-separate-dark", .separateKeys, true)] {
            let file = SettingsFile(url: directory.appending(path: "\(name).json"))
            try? file.save(AppSettings(hotkeys: preset.hotkeys))
            let store = SettingsStore(file: file)
            let size = CGSize(width: 560, height: 980)
            render(ShortcutsPane(store: store, recording: ShortcutRecording(store: store), languages: languages)
                .frame(width: size.width, height: size.height), dark: dark, size: size,
                to: directory.appending(path: "\(name).png"))
        }
        let file = SettingsFile(url: directory.appending(path: "three.json"))
        try? file.save(AppSettings())
        let store = SettingsStore(file: file)
        let updates = Updates(store: store, preview: ManagedSettings(), configured: true, lastCheck: nil)
        let size = CGSize(width: 560, height: 1000)
        render(GeneralPane(store: store, updates: updates, layouts: sources.layouts).frame(width: size.width, height: size.height),
               dark: false, size: size, to: directory.appending(path: "general-three-light.png"))
        render(GeneralPane(store: store, updates: updates, layouts: sources.layouts).frame(width: size.width, height: size.height),
               dark: true, size: size, to: directory.appending(path: "general-three-dark.png"))
        let onboardingSize = NSSize(width: 640, height: 580)
        for dark in [false, true] {
            let model = OnboardingModel(store: store, sources: sources, step: .welcome, live: false)
            render(OnboardingView(model: model), dark: dark, size: onboardingSize,
                   to: directory.appending(path: "onboarding-1-welcome-three-\(dark ? "dark" : "light").png"))
        }
        let pause = PauseState(frozen: PauseSet(), now: Date())
        let appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
        appModes.freeze(frontmost: FrontApp(bundleID: "com.apple.Notes", name: "Notes", isGame: false))
        let menu = MenuContent(sources: sources, store: store, pause: pause,
                               appModes: appModes, recents: RecentCorrections())
        render(menu, dark: false, size: CGSize(width: 318, height: 560), to: directory.appending(path: "menu-three-light.png"))
    }

    /// The menu with everything on: a repeated correction among five, four dictations and an unsaved one, a held
    /// card, voice, three layouts. `short` has room for 700pt only, so its lower part scrolls;
    /// `layouts` has the header's list open. Prints the height each one takes.
    private static func renderCrowdedMenus(in directory: URL) {
        let sources = threeLayouts()
        let now = Date()
        var held = PauseSet()
        held.pause(until: now.addingTimeInterval(59 * 60 - 30))
        let file = SettingsFile(url: directory.appending(path: "menu-crowded.json"))
        try? file.save(AppSettings())
        let store = SettingsStore(file: file)
        let pause = PauseState(frozen: held, now: now)
        let appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
        appModes.freeze(frontmost: FrontApp(bundleID: "com.apple.Terminal", name: "Terminal", isGame: false))
        let updates = Updates(store: store, preview: ManagedSettings(), configured: true, lastCheck: nil)
        var log = CorrectionLog()
        let words = ["ghbdtn", "мвд", "еще", "чтото", "vbh"]
        // One correction three times among others, then four more kinds: five rows.
        for (seq, index) in [0, 1, 0, 2, 0, 3, 4].enumerated() {
            let word = words[index]
            log.record(Correction(seq: UInt32(seq + 1), original: word, replacement: word.uppercased(),
                                  source: "en", target: "ru", kind: index == 0 ? .layout : .abbreviation), at: now)
        }
        var actions = MenuActions()
        #if PEREKEY_VOICE
        let controller = voiceTextPreview(in: directory, name: "menu-crowded")
        // The last one went into a field the app could not read: it waits in memory, above the stored ones.
        controller.history.record(DictationRecord(text: "Напомни завтра про созвон с Антоном в одиннадцать.", bundleID: "com.apple.Terminal",
                                                  appName: "Terminal", duration: 3, model: "parakeet-tdt-v3", pasted: false,
                                                  privacy: .unknown))
        actions.dictation = controller.menu(pasteAgain: { _ in })
        actions.voiceModes = VoiceModeMenu(store: modesPreview(), isOn: { true })
        actions.transcripts = TranscriptsMenu(isOn: { true }, open: {})
        actions.transcribeFile = {}
        actions.canTranscribeFiles = { true }
        actions.callRecording = CallRecordingController(capture: AudioCapture(), settings: voicePreview(in: directory, name: "menu-crowded").settings,
                                                   isSupported: { true })
        #endif
        let cases: [(name: String, budget: CGFloat, open: Bool)] = [
            ("crowded", .infinity, false), ("short", 700, false),
            ("layouts", .infinity, true), ("short-layouts", 700, true),
        ]
        for dark in [false, true] {
            for item in cases {
                let presentation = MenuPresentation()
                presentation.budget = item.budget
                var content = MenuContent(sources: sources, store: store, pause: pause, appModes: appModes,
                                          recents: RecentCorrections(log), actions: actions, updates: updates)
                content.presentation = presentation
                content.layoutsOpenAtStart = item.open
                let height = fittedHeight(of: content, dark: dark)
                print("menu-\(item.name)-\(dark ? "dark" : "light"): \(Int(height)) pt")
                render(content, dark: dark, size: CGSize(width: 318, height: max(height, 100)),
                       to: directory.appending(path: "menu-\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The height the menu takes in its panel: the hosting view's fitting size.
    private static func fittedHeight(of view: some View, dark: Bool) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.pkLiquidGlass, liquidGlass))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 318, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return host.fittingSize.height
    }

    /// A recorder with a week of made-up counts, in a file of its own.
    private static func sampleUsage(in directory: URL, name: String) -> UsageRecorder {
        var clock = Date()
        let file = UsageStatsFile(url: directory.appending(path: "\(name).stats.json"))
        file.erase()
        let recorder = UsageRecorder(file: file, interval: 0, now: { clock }) { true }
        let kinds: [Correction.Kind] = [.layout, .layout, .layout, .typo, .yo, .abbreviation, .capsLock, .hyphen]
        let perDay = [4, 11, 7, 0, 19, 9, 23]
        for (index, count) in perDay.enumerated() {
            clock = Calendar.current.date(byAdding: .day, value: index - 6, to: Date()) ?? Date()
            for n in 0..<count { recorder.recordCorrection(kinds[n % kinds.count]) }
            if count > 8 { recorder.recordUndo() }
        }
        recorder.recordUndo()
        clock = Date()
        return recorder
    }

    /// Settings → General with statistics off and on, and the menu line.
    private static func renderStatistics(in directory: URL) {
        let size = CGSize(width: 560, height: 1500)
        for (name, on, dark) in [("statistics-off-light", false, false), ("statistics-on-light", true, false), ("statistics-on-dark", true, true)] {
            let file = SettingsFile(url: directory.appending(path: "\(name).json"))
            var settings = AppSettings()
            settings.statistics = on
            try? file.save(settings)
            let store = SettingsStore(file: file)
            let updates = Updates(store: store, preview: ManagedSettings(), configured: true, lastCheck: nil)
            let usage = on ? sampleUsage(in: directory, name: name) : UsageRecorder(file: UsageStatsFile(url: directory.appending(path: "\(name).stats.json"))) { false }
            render(PrivacyPane(store: store, usage: usage, languages: LanguageStatsStore(file: nil)).frame(width: size.width, height: size.height),
                   dark: dark, size: size, to: directory.appending(path: "\(name).png"))
        }
        let sources = InputSources()
        let file = SettingsFile(url: directory.appending(path: "menu-statistics.json"))
        var settings = AppSettings()
        settings.statistics = true
        try? file.save(settings)
        let store = SettingsStore(file: file)
        let pause = PauseState(frozen: PauseSet(), now: Date())
        let appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
        let view = MenuContent(sources: sources, store: store, pause: pause,
                               appModes: appModes, recents: RecentCorrections(),
                               usage: sampleUsage(in: directory, name: "menu-statistics"))
        render(view, dark: false, size: CGSize(width: 318, height: 560), to: directory.appending(path: "menu-statistics.png"))
    }

    /// The Words pane with sample words (and a frequent-word warning), and the General pane.
    private static func renderWordsAndGeneral(in directory: URL) {
        var words = WordRules(mine: ["перекей", "kubectl", "ё-моё"], always: ["аня", "гошан"])
        words.learned = [
            LearnedWord(word: "дедлайн", learnedAt: Date().addingTimeInterval(-86_400 * 2).timeIntervalSince1970),
            LearnedWord(word: "ghbdtn", learnedAt: Date().addingTimeInterval(-86_400 * 20).timeIntervalSince1970,
                        undoCount: 3, lastUndoneAt: Date().addingTimeInterval(-86_400 * 4).timeIntervalSince1970),
        ]
        let size = CGSize(width: 560, height: 1100)
        for (name, sample, dark) in [("words-light", words, false), ("words-empty-dark", WordRules(), true)] {
            let file = SettingsFile(url: directory.appending(path: "\(name).json"))
            try? file.save(AppSettings(words: sample))
            let view = WordsPane(store: SettingsStore(file: file)).frame(width: size.width, height: size.height)
            render(view, dark: dark, size: size, to: directory.appending(path: "\(name).png"))
        }
        let general = SettingsStore(file: SettingsFile(url: directory.appending(path: "general.json")))
        let generalSize = CGSize(width: size.width, height: 1000)
        let updateStates: [(name: String, managed: ManagedSettings, configured: Bool, lastCheck: Date?, dark: Bool)] = [
            ("general-light", ManagedSettings(), true, Date().addingTimeInterval(-3_600 * 5), false),
            ("general-managed-light", ManagedSettings(updatesDisabled: true), true, nil, false),
            ("general-devbuild-dark", ManagedSettings(), false, nil, true),
        ]
        for state in updateStates {
            let updates = Updates(store: general, preview: state.managed, configured: state.configured, lastCheck: state.lastCheck)
            render(GeneralPane(store: general, updates: updates).frame(width: generalSize.width, height: generalSize.height),
                   dark: state.dark, size: generalSize, to: directory.appending(path: "\(state.name).png"))
        }
        let soundsFile = SettingsFile(url: directory.appending(path: "general-sounds.json"))
        try? soundsFile.save(AppSettings(layoutSound: SoundSetting(isOn: true, name: "Pop"),
                                         correctionSound: SoundSetting(isOn: false, name: "Glass")))
        let soundsStore = SettingsStore(file: soundsFile)
        let soundsUpdates = Updates(store: soundsStore, preview: ManagedSettings(), configured: true, lastCheck: nil)
        render(GeneralPane(store: soundsStore, updates: soundsUpdates).frame(width: size.width, height: 460), dark: true,
               size: CGSize(width: size.width, height: 460), to: directory.appending(path: "general-sounds-dark.png"))
        for (name, word, dark) in [("report-light", "ghbdtn", false), ("report-nothing-dark", "", true)] {
            let sheet = ReportWordSheet(initialWord: word, layouts: ["ABC", "Russian"],
                                        version: "Perekey 0.1 (1), macOS 14.5", onOpen: { _ in }, onCancel: {})
            render(sheet, dark: dark, size: CGSize(width: 520, height: 640), to: directory.appending(path: "\(name).png"))
        }
        let store = SettingsStore(file: SettingsFile(url: directory.appending(path: "words-warn.json")))
        let warn = WordsPane(store: store, isFrequent: { _ in true }, initialDraft: "привет")
        render(warn.frame(width: size.width, height: size.height), dark: false, size: size,
               to: directory.appending(path: "words-warning-light.png"))
    }

    /// An explanation as the hint shows it after a manual retype.
    private static var sampleWhy: HintWhy {
        let decision = Classifier.Decision(verdict: .keep, score: 4.2, reason: .compared, language: "en", margin: 10,
                                           typedForm: .rare, otherForm: .known, typedLanguage: "en",
                                           otherLanguage: "ru")
        let explanation = Explanation(decision: decision, typed: "Fyz", other: "Аня")
        return HintWhy(title: ExplanationText.title(switched: explanation.switched),
                       lines: ExplanationText.lines(explanation))
    }

    /// A «Recent corrections» row with its reasons open.
    private static func renderReasons(in directory: URL) {
        var log = CorrectionLog()
        let en = LayoutID("en"), ru = LayoutID("ru")
        var layout = Correction(seq: 1, original: "ghbdtn", replacement: "привет", source: en, target: ru)
        layout.decision = Classifier.Decision(verdict: .switch(to: ru), score: 38.4, reason: .compared, language: "ru",
                                              margin: 10, typedForm: .unknown, otherForm: .known, typedLanguage: "en",
                                              otherLanguage: "ru")
        var typo = Correction(seq: 2, original: "прривет", replacement: "привет", source: ru, target: ru, kind: .typo)
        typo.typoChange = .delete
        var inside = Correction(seq: 3, original: "ghb", replacement: "при", source: en, target: ru)
        inside.insideWord = true
        inside.decision = Classifier.Decision(verdict: .keep, score: 0, reason: .compared, language: nil,
                                              typedLanguage: "en")
        for correction in [inside, typo, layout] { log.record(correction) }
        let file = SettingsFile(url: directory.appending(path: "reasons.json"))
        try? file.save(AppSettings())
        let store = SettingsStore(file: file)
        let nav = MenuNav()
        for dark in [false, true] {
            let rows = VStack(spacing: 4) {
                ForEach(log.entries) { entry in
                    CorrectionRow(entry: entry, isLatest: false, store: store, nav: nav, onReport: { _, _ in },
                                  explained: true)
                }
            }
            .padding(12)
            render(rows, dark: dark, size: CGSize(width: 318, height: 330),
                   to: directory.appending(path: "reasons-rows-\(dark ? "dark" : "light").png"))
        }
    }

    /// The caret hint in every state, light and dark, and the glass strip
    /// correction in key frames.
    private static func renderHint(in directory: URL) {
        let states: [(String, HintContent)] = [
            ("corrected", .corrected(original: "ghbdtn", replacement: "привет")),
            ("retyped", .retyped(original: "ghbdtn", word: "привет", shortcut: "⌥", why: nil, offersAlways: false)),
            ("retyped-why", .retyped(original: "Fyz", word: "Аня", shortcut: "⌥", why: Self.sampleWhy, offersAlways: true)),
            ("always-fixed", .alwaysFixed(word: "аня")),
            ("always-withdrawn", .alwaysFixWithdrawn(word: "аня")),
            ("learned", .learned(word: "дедлайн")),
        ]
        for (name, content) in states {
            for dark in [false, true] {
                let model = HintModel(content: content, visible: true)
                render(HintView(model: model) {}, dark: dark, size: CGSize(width: 320, height: 90),
                       to: directory.appending(path: "hint-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        for dark in [false, true] {
            let model = HintModel(content: .retyped(original: "Fyz", word: "Аня", shortcut: "⌥", why: Self.sampleWhy,
                                                    offersAlways: true),
                                  visible: true, expanded: true)
            render(HintView(model: model) {}, dark: dark, size: CGSize(width: 360, height: 190),
                   to: directory.appending(path: "hint-retyped-why-open-\(dark ? "dark" : "light").png"))
        }
        for (progress, style) in [(0.0, GlassStripStyle.fix), (0.25, .fix), (0.45, .fix), (0.7, .fix), (1, .fix),
                                  (0.45, .undo)]
        {
            for dark in [false, true] {
                let model = HintModel(content: .corrected(original: "ghbdtn", replacement: "привет"), visible: true,
                                      stripProgress: progress, stripStyle: style)
                let tag = "\(style == .undo ? "undo" : "fix")-\(Int(progress * 100))"
                render(HintView(model: model) {}, dark: dark, size: CGSize(width: 320, height: 90),
                       to: directory.appending(path: "hint-strip-\(tag)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The glass strip in the settings chip, the demo field and the hero.
    private static func renderStrips(in directory: URL) {
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let chips: [(String, Bool, Double, GlassStripStyle)] = [
                ("off", false, 1, .fix), ("on", true, 1, .fix), ("fix-30", true, 0.3, .fix),
                ("fix-50", true, 0.5, .fix), ("fix-75", true, 0.75, .fix), ("undo-30", false, 0.3, .undo),
                ("undo-50", false, 0.5, .undo),
            ]
            let column = VStack(alignment: .leading, spacing: 8) {
                ForEach(chips, id: \.0) { chip in
                    PKExampleChip(from: "прривет", to: "привет", isOn: chip.1, phase: (chip.2, chip.3))
                }
            }
            .padding(16)
            render(column.fixedSize(), dark: dark, size: CGSize(width: 240, height: 330),
                   to: directory.appending(path: "strip-chip-\(suffix).png"))
            for (tag, progress, style) in [("fix-35", 0.35, GlassStripStyle.fix), ("fix-60", 0.6, .fix),
                                           ("undo-45", 0.45, .undo)]
            {
                let field = Text(verbatim: tag.hasPrefix("undo") ? "ghbdtn" : "привет")
                    .font(.system(size: 20))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 10)
                    .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
                    .overlay {
                        GlassStripSweep(progress: progress, style: style,
                                        word: tag.hasPrefix("undo") ? "ghbdtn" : "привет", font: .systemFont(ofSize: 20))
                    }
                    .padding(16)
                render(field, dark: dark, size: CGSize(width: 360, height: 72),
                       to: directory.appending(path: "strip-demo-\(tag)-\(suffix).png"))
            }
            for phase in [0.5, 1.5, 2.0, 3.5, 4.5] {
                render(GlassStripHero(phase: phase).padding(20), dark: dark, size: CGSize(width: 420, height: 130),
                       to: directory.appending(path: "strip-hero-\(Int(phase * 10))-\(suffix).png"))
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
        for (name, status) in [("denied", OnboardingModel.AccessStatus.denied), ("granted", .granted)] {
            let model = OnboardingModel(store: store, sources: sources, step: .access, live: false)
            model.fakeAccess(status)
            render(OnboardingView(model: model), dark: false, size: size,
                   to: directory.appending(path: "onboarding-2-access-\(name).png"))
        }
        render(OnboardingView(model: OnboardingModel(store: store, sources: sources, step: .preset, live: false)),
               dark: true, size: size, to: directory.appending(path: "onboarding-3-preset-dark.png"))
        let system = OnboardingModel(store: store, sources: sources, step: .preset, live: false)
        system.choose(.system)
        render(OnboardingView(model: system), dark: false, size: size,
               to: directory.appending(path: "onboarding-3-preset-system.png"))
        system.choose(.default)
        for (name, undone) in [("auto", false), ("auto-undone", true)] {
            let model = OnboardingModel(store: store, sources: sources, step: .demo, live: false)
            model.fakeAutoDemo(undone: undone)
            render(OnboardingView(model: model), dark: false, size: size,
                   to: directory.appending(path: "onboarding-4-demo-\(name).png"))
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

#if PEREKEY_VOICE
extension DebugSnapshot {
    /// A model in each state the Voice tab shows.
    /// `.running`: a download goes on. `.stopped`: voice is off, so nothing downloads and a stopped one is `partial`.
    /// `.administrator`: a profile forbids downloads, so the models come from the administrator's folder.
    /// `pending`: Ultra picked while it downloads; `empty`: a first start, nothing on disk.
    enum PreviewStates { case running, stopped, administrator, pending, empty }

    static func voicePreview(in directory: URL, name: String, managed: ManagedSettings = ManagedSettings(),
                             enabled: Bool = true, supported: Bool = true,
                             states: PreviewStates = .running) -> VoiceModelsController
    {
        let file = VoiceSettingsFile(url: directory.appending(path: "\(name)-voice.json"))
        try? FileManager.default.removeItem(at: file.url)
        try? file.save(VoiceSettings(isEnabled: enabled, microphoneUID: "gone-usb-mic", microphoneName: "Rode NT-USB"))
        let settings = VoiceSettingsStore(file: file, managed: managed)
        let parakeet = ModelCatalog.entry(id: "parakeet-tdt-v3")!
        let whisper = ModelCatalog.recognizers.first { $0.engine == .whisperKit }!
        let others = ModelCatalog.recognizers.filter { $0.id != parakeet.id && $0.id != whisper.id }
        var statuses: [VoiceModelStatus]
        switch states {
        case .running:
            statuses = [
                VoiceModelStatus(entry: parakeet, state: .ready, isInUse: true),
                VoiceModelStatus(entry: whisper, state: .downloading(received: whisper.totalSize * 42 / 100)),
            ]
            statuses += others.map {
                VoiceModelStatus(entry: $0, state: .partial(received: $0.totalSize / 3),
                                 failure: .notEnoughSpace(needed: $0.totalSize, available: 200_000_000))
            }
        case .stopped:
            statuses = [
                VoiceModelStatus(entry: parakeet, state: .ready),
                VoiceModelStatus(entry: whisper, state: .partial(received: whisper.totalSize * 42 / 100)),
            ]
            statuses += others.map { VoiceModelStatus(entry: $0, state: .absent) }
        case .pending:
            statuses = [
                VoiceModelStatus(entry: parakeet, state: .ready, isInUse: true),
                VoiceModelStatus(entry: whisper, state: .absent),
            ]
            statuses += others.map { VoiceModelStatus(entry: $0, state: .downloading(received: $0.totalSize * 68 / 100)) }
        case .empty:
            statuses = [
                VoiceModelStatus(entry: parakeet, state: .absent),
                VoiceModelStatus(entry: whisper, state: .absent),
            ]
            statuses += others.map { VoiceModelStatus(entry: $0, state: .absent) }
        case .administrator:
            statuses = [
                VoiceModelStatus(entry: parakeet, state: .ready, isManaged: true),
                VoiceModelStatus(entry: whisper, state: .absent),
            ]
            statuses += others.map {
                VoiceModelStatus(entry: $0, state: .damaged, failure: .checksumMismatch("model.mil"))
            }
        }
        let controller = VoiceModelsController(preview: settings, statuses: statuses,
                                               usage: VoiceModelDiskUsage(models: 1_100_000_000, cache: 140_000_000),
                                               isSupported: supported)
        if states == .pending, let ultra = others.first { controller.previewPending(ultra.id) }
        return controller
    }

    /// Modes as a person who set up OpenAI for mail would have them.
    static func modesPreview(managed: ManagedSettings = ManagedSettings()) -> VoiceModesStore {
        var modes = VoiceModeSet.defaults(VoiceModesStore.localized)
        // "Message" on Ollama, "Email" on OpenAI, as picked in the tab; "Clean copy" not set up yet.
        for (mode, preset) in [(BuiltInMode.message, VoiceEndpoint.Preset.ollama), (.mail, .openAI)] {
            guard let index = modes.modes.firstIndex(where: { $0.id == mode.rawValue }),
                  let prompt = VoiceModesStore.localized(mode).prompt
            else { continue }
            modes.modes[index].refine = RefineConfig(endpoint: preset.rawValue, model: preset.suggestedModel, prompt: prompt)
        }
        modes.consent([.text, .selection, .app], endpoint: VoiceEndpoint.Preset.openAI.rawValue)
        return VoiceModesStore(preview: modes, keyed: [VoiceEndpoint.Preset.openAI.rawValue], managed: managed)
    }

    /// The Voice modes tab, tall enough to show it whole: a local LLM mode,
    /// a cloud one, the terminal mode, and the cloud off by a profile.
    static func renderModes(in directory: URL) {
        let models = voicePreview(in: directory, name: "modes")
        let cases: [(name: String, mode: String, managed: ManagedSettings)] = [
            ("modes-message", BuiltInMode.message.rawValue, ManagedSettings()),
            ("modes-mail", BuiltInMode.mail.rawValue, ManagedSettings()),
            ("modes-terminal", BuiltInMode.terminal.rawValue, ManagedSettings()),
            ("modes-cloud-disabled", BuiltInMode.clean.rawValue, ManagedSettings(voiceCloudDisabled: true)),
        ]
        for item in cases {
            for dark in [false, true] {
                let view = ModesPane(store: modesPreview(managed: item.managed), models: models, selected: item.mode)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 624, height: 1560),
                       to: directory.appending(path: "\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// The Voice tab on its own: on, off, a profile that forbids voice or downloads, an unsupported Mac.
    static func renderVoice(in directory: URL) {
        let store = SettingsStore(file: SettingsFile(url: directory.appending(path: "voice-hotkeys.json")))
        let recording = ShortcutRecording(store: store)
        let cases: [(name: String, controller: VoiceModelsController)] = [
            ("on", voicePreview(in: directory, name: "on")),
            ("off", voicePreview(in: directory, name: "off", enabled: false, states: .stopped)),
            ("voice-disabled", voicePreview(in: directory, name: "vd", managed: ManagedSettings(voiceDisabled: true))),
            ("downloads-disabled", voicePreview(in: directory, name: "dd",
                                                managed: ManagedSettings(voiceModelDownloadsDisabled: true),
                                                states: .administrator)),
            ("unsupported", voicePreview(in: directory, name: "un", supported: false)),
            ("pending", voicePreview(in: directory, name: "pe", states: .pending)),
            ("empty", voicePreview(in: directory, name: "em", states: .empty)),
        ]
        for dark in [false, true] {
            for item in cases {
                let view = VoicePane(controller: item.controller, store: store, recording: recording)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 620, height: 1_240),
                       to: directory.appending(path: "voice-\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// A text controller with a made-up dictionary and a few dictations, in files of its own.
    static func voiceTextPreview(in directory: URL, name: String, managed: ManagedSettings = ManagedSettings()) -> VoiceTextController {
        let folder = directory.appending(path: "\(name)-history", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        let textFile = VoiceTextSettingsFile(url: directory.appending(path: "\(name)-voice-text.json"))
        try? FileManager.default.removeItem(at: textFile.url)
        var settings = VoiceTextSettings()
        settings.dictionary += [DictionaryEntry(from: "ай фон", to: "iPhone"), DictionaryEntry(from: "ка эн ка", to: "KNK")]
        try? textFile.save(settings)
        let controller = VoiceTextController(managed: managed, textFile: textFile, historyFile: DictationHistoryFile(directory: folder))
        var clock = Date().addingTimeInterval(-3 * 3_600)
        let samples: [(String, String, String)] = [
            ("Перекей отлично работает в заметках, проверь пожалуйста ещё раз.", "com.apple.Notes", "Notes"),
            ("Let's move the review to Thursday afternoon.", "com.apple.mail", "Mail"),
            ("Купить молоко, хлеб и сыр, а ещё забрать посылку.", "com.apple.Notes", "Notes"),
            ("The build is green, merging now.", "com.apple.Terminal", "Terminal"),
        ]
        let history = DictationHistory(file: DictationHistoryFile(directory: folder), managed: managed,
                                       settings: { controller.text.settings }, now: { clock })
        for sample in samples {
            clock = clock.addingTimeInterval(40 * 60)
            history.record(DictationRecord(text: sample.0, bundleID: sample.1, appName: sample.2, duration: 4,
                                           model: "parakeet-tdt-v3", pasted: true))
        }
        // The file is written on the history's own queue: the controller below reads it.
        history.flush()
        return VoiceTextController(managed: managed, textFile: textFile, historyFile: DictationHistoryFile(directory: folder))
    }

    /// The Text and History groups, and the menu with the recent dictations.
    static func renderVoiceText(in directory: URL) {
        let cases: [(name: String, managed: ManagedSettings)] = [
            ("text", ManagedSettings()),
            ("text-limited", ManagedSettings(voiceHistoryMaxDays: 7)),
        ]
        for dark in [false, true] {
            for item in cases {
                let controller = voiceTextPreview(in: directory, name: item.name, managed: item.managed)
                let view = VStack(alignment: .leading, spacing: 16) {
                    VoiceTextGroup(controller: controller)
                    VoiceHistoryGroup(controller: controller)
                }
                .padding(24)
                .frame(width: 620, height: 660, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 620, height: 660),
                       to: directory.appending(path: "voice-\(item.name)-\(dark ? "dark" : "light").png"))
            }
            let controller = voiceTextPreview(in: directory, name: "menu")
            // A paste into a field with no accessibility element: held in memory, shown on top.
            controller.history.record(DictationRecord(
                text: "Что касается картинок, смотри, вот я открыл превью и там пусто.", bundleID: "com.stablyai.orca",
                appName: "Orca", duration: 6, model: "parakeet-tdt-v3", pasted: true, privacy: .unknown))
            let sources = InputSources()
            let store = SettingsStore(file: SettingsFile(url: directory.appending(path: "voice-menu.json")))
            let pause = PauseState(frozen: PauseSet(), now: Date())
            let appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
            var actions = MenuActions()
            actions.dictation = controller.menu(pasteAgain: { _ in })
            let menu = MenuContent(sources: sources, store: store, pause: pause,
                                   appModes: appModes, recents: RecentCorrections(), actions: actions)
                .background(Color(nsColor: .windowBackgroundColor))
            render(menu, dark: dark, size: CGSize(width: 318, height: 700),
                   to: directory.appending(path: "voice-menu-\(dark ? "dark" : "light").png"))
        }
    }

    /// The dictation HUD in every state, over a soft backdrop.
    static func renderVoiceHUD(in directory: URL) {
        typealias Recording = DictationHUDState.Recording
        let rec = DictationHUDState.recording(Recording(seconds: 7, level: 0.6, preparingModel: false))
        let states: [(name: String, state: DictationHUDState, calm: Bool, contrast: Bool)] = [
            ("starting", .starting, false, false),
            ("recording", rec, false, false),
            ("recording-quiet", .recording(Recording(seconds: 2, level: 0.05, preparingModel: false)), false, false),
            ("recording-loud", .recording(Recording(seconds: 63, level: 1, preparingModel: false)), false, false),
            ("recording-calm", rec, true, false),
            ("recording-contrast", rec, false, true),
            ("recording-preparing", .recording(Recording(seconds: 3, level: 0.4, preparingModel: true)), false, false),
            ("recognizing", .recognizing(preparingModel: false), false, false),
            ("recognizing-preparing", .recognizing(preparingModel: true), false, false),
            ("still-recognizing", .stillRecognizing, false, false),
            ("pasting", .pasting, false, false),
            ("pasted", .pasted, false, false),
            ("not-pasted", .notPasted(.targetChanged), false, false),
            ("not-pasted-contrast", .notPasted(.targetChanged), false, true),
            ("not-pasted-timeout", .notPasted(.timedOut), false, false),
            ("not-pasted-interrupted", .notPasted(.interrupted), false, false),
            ("password-field", .notPasted(.secureField), false, false),
            ("secure-input", .notPasted(.secureInput(owner: "Terminal")), false, false),
            ("secure-input-unknown", .notPasted(.secureInput(owner: nil)), false, false),
            ("no-accessibility", .notPasted(.noAccessibility), false, false),
            ("nothing-heard", .nothingHeard, false, false),
            ("cancelled", .cancelled, false, false),
            ("mic-denied", .failed(.microphoneDenied), false, false),
            ("no-microphone", .failed(.noMicrophone), false, false),
            ("mic-error", .failed(.microphone("x")), false, false),
            ("model", .failed(.model("x")), false, false),
            ("recognition", .failed(.recognition("x")), false, false),
            ("recording-mode-cloud", .recording(Recording(seconds: 4, level: 0.5, preparingModel: false,
                                                          mode: "Письмо", cloudHost: "api.openai.com")), false, false),
            ("refining", .refining(.init(mode: "Сообщение", endpoint: "Ollama", isCloud: false)), false, false),
            ("refining-cloud", .refining(.init(mode: "Письмо", endpoint: "OpenAI", isCloud: true)), false, false),
            ("pasted-as-said", .pastedFallback(.answered), false, false),
            ("pasted-as-said-escape", .pastedFallback(.escape), false, false),
            ("pasted-needs-consent", .pastedFallback(.needsConsent(host: "api.openai.com")), false, false),
            ("copied", .copied, false, false),
        ]
        for dark in [false, true] {
            for item in states {
                guard let presentation = DictationHUDPresentation(item.state) else { continue }
                let model = VoiceHUDModel(presentation, visible: true)
                let hud = VoiceHUDView(model: model, calmOverride: item.calm, contrastOverride: item.contrast)
                let size = NSHostingView(rootView: hud).fittingSize
                let backdrop = LinearGradient(
                    colors: dark ? [Color(red: 0.13, green: 0.13, blue: 0.2), Color(red: 0.2, green: 0.14, blue: 0.22)]
                        : [Color(red: 0.86, green: 0.87, blue: 1), Color(red: 0.97, green: 0.88, blue: 0.94)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                render(hud.background(backdrop), dark: dark, size: size,
                       to: directory.appending(path: "voice-hud-\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    /// "What's new: voice input", the voice step of the first-run window, and how each looks with another key.
    static func renderVoiceIntro(in directory: URL) {
        let size = NSSize(width: 640, height: 580)
        func model(_ name: String, hotkeys: AppSettings? = nil) -> VoiceIntroModel {
            let file = SettingsFile(url: directory.appending(path: "intro-\(name).json"))
            try? file.save(hotkeys ?? AppSettings())
            let store = SettingsStore(file: file)
            let controller = voicePreview(in: directory, name: "intro-\(name)", enabled: false, states: .stopped)
            return VoiceIntroModel(settings: controller.settings, models: controller, store: store,
                                   recording: ShortcutRecording(store: store))
        }
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            render(VoiceIntroView(model: model("default")), dark: dark, size: size,
                   to: directory.appending(path: "voice-intro-\(tag).png"))
            let own = model("own")
            own.choose(.hold(keyCode: 49, modifiers: [.option]))
            own.isPickingKey = true
            render(VoiceIntroView(model: own), dark: dark, size: size,
                   to: directory.appending(path: "voice-intro-own-key-\(tag).png"))
            let taken = model("taken", hotkeys: AppSettings(hotkeys: HotkeyPreset.separateKeys.hotkeys, capsLock: .system))
            render(VoiceIntroView(model: taken), dark: dark, size: size,
                   to: directory.appending(path: "voice-intro-taken-\(tag).png"))
            let step = model("step")
            let file = SettingsFile(url: directory.appending(path: "intro-step-onboarding.json"))
            try? file.save(AppSettings())
            let onboarding = OnboardingModel(store: SettingsStore(file: file), sources: InputSources(), step: .voice, live: false)
            onboarding.voiceIntro = step
            render(OnboardingView(model: onboarding, heroPhase: 4.5), dark: dark, size: size,
                   to: directory.appending(path: "voice-onboarding-step-\(tag).png"))
        }
    }
}
#endif

#if PEREKEY_VOICE
extension DebugSnapshot {
    /// A file queue that says fixed phases and queues nothing.
    private final class PreviewQueue: FileTranscribing {
        let snapshot: [UUID: TranscriptionPhase]
        init(_ snapshot: [UUID: TranscriptionPhase]) { self.snapshot = snapshot }
        func enqueue(_ job: TranscriptionJob) async {}
        func cancel(_ recording: UUID) async {}
        func phases() -> AsyncStream<[UUID: TranscriptionPhase]> {
            let snapshot = snapshot
            return AsyncStream { continuation in
                continuation.yield(snapshot)
                continuation.finish()
            }
        }
        var isBusy: Bool { false }
    }

    /// Ids of the made-up recordings by what they show.
    struct TranscriptsFixture {
        var controller: TranscriptsController
        var interview: UUID
        var zoom: UUID
        var running: UUID
        var failed: UUID
        var interrupted: UUID
        var expired: UUID
    }

    /// Recordings in every status of the list, in a folder of their own, with a queue that never runs.
    static func transcriptsPreview(in directory: URL, name: String, empty: Bool = false,
                                   managed: ManagedSettings = ManagedSettings()) -> TranscriptsFixture
    {
        let root = directory.appending(path: "\(name)-recordings", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        let folder = RecordingsFolder(root: root)
        let voiceFile = VoiceSettingsFile(url: directory.appending(path: "\(name)-voice.json"))
        try? FileManager.default.removeItem(at: voiceFile.url)
        try? voiceFile.save(VoiceSettings(isEnabled: true))
        let voice = VoiceSettingsStore(file: voiceFile, managed: managed)
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
        func file(_ name: String, hours: Double, duration: Double) -> RecordingMeta {
            var meta = RecordingMeta.file(FileReference(path: "/Users/anna/Movies/\(name)"), createdAt: ago(hours))
            meta.duration = duration
            return meta
        }
        func call(_ app: String, hours: Double, duration: Double, state: RecordingMeta.State = .done) -> RecordingMeta {
            var meta = RecordingMeta.call(source: .app(bundleID: "us.zoom.xos", name: app), startHostTime: 1,
                                          createdAt: ago(hours), audioRetention: .month)
            meta.state = state
            meta.duration = duration
            meta.segments = [
                RecordingMeta.Segment(track: .mic, file: "mic-0001.aac", startHostTime: 1, startOffset: 0,
                                      frames: Int64(duration * 16_000), closed: state != .recording),
                RecordingMeta.Segment(track: .sys, file: "sys-0001.aac", startHostTime: 1, startOffset: 0,
                                      frames: Int64(duration * 16_000), closed: state != .recording),
            ]
            return meta
        }
        func phrase(_ start: Double, _ text: String, _ speaker: String?) -> TimedSegment {
            TimedSegment(start: start, end: start + 5 + Double(text.count) / 25, text: text, speaker: speaker)
        }
        let interviewText = TranscriptDocument(model: "parakeet-tdt-v3", engine: "parakeet", language: "ru", segments: [
            phrase(1, "Давайте начнём. Расскажите, как вы пришли в проект?", "speaker-1"),
            phrase(9, "Я пришла полгода назад, когда команде нужен был человек на отчёты.", "speaker-2"),
            phrase(21, "То есть сначала это были только отчёты, а потом стало больше?", "speaker-1"),
            phrase(30, "Да. Сначала отчёт раз в неделю, потом ежедневный, потом ещё и разбор ошибок.", "speaker-2"),
            phrase(44, "Звучит как много работы. Что помогало не выгореть?", "speaker-1"),
            phrase(53, "Честно, договорённость, что отчёт не пишется после шести вечера.", "speaker-2"),
            phrase(66, "Хорошее правило. А как команда к нему отнеслась?", "speaker-1"),
            phrase(75, "Сначала удивились, потом сами стали так делать. Отчёт стал короче.", "speaker-2"),
            phrase(88, "И последнее: что бы вы посоветовали новичку?", "speaker-1"),
            phrase(96, "Спрашивать сразу. Никто не ждёт, что вы всё знаете в первую неделю.", "speaker-2"),
        ])
        var interviewDoc = interviewText
        interviewDoc.rename(speaker: "speaker-2", to: "Аня")
        let zoomDoc = TranscriptDocument(model: "whisper-large-v3-turbo", engine: "whisper", language: "ru", segments: [
            phrase(2, "Всем привет, слышно меня?", "me"),
            phrase(8, "Да, слышим хорошо. Начнём с итогов недели.", "others"),
            phrase(17, "По релизу всё готово, ждём только подпись от юристов.", "me"),
            phrase(27, "Хорошо. Тогда в четверг выкатываем, если нет возражений.", "others"),
            phrase(38, "Возражений нет. Отчёт по тестам я отправлю до пятницы.", "me"),
        ])
        var items: [(UUID, RecordingMeta, TranscriptDocument?)] = []
        let interview = UUID(), zoom = UUID(), running = UUID(), failed = UUID(), interrupted = UUID(), expired = UUID()
        let queued = UUID(), preparing = UUID(), waiting = UUID(), diarizing = UUID()
        var expiredMeta = call("Zoom", hours: 150, duration: 1_260)
        expiredMeta.audioRemovedAt = ago(5)
        if !empty {
            items = [
                (interview, file("Интервью с Аней.m4a", hours: 2, duration: 1_245), interviewDoc),
                (zoom, call("Zoom", hours: 26, duration: 2_460), zoomDoc),
                (running, file("Лекция по акустике.mp4", hours: 0.2, duration: 5_420), nil),
                (queued, file("Подкаст, выпуск 14.mp3", hours: 0.3, duration: 3_100), nil),
                (preparing, file("Планёрка.m4a", hours: 0.4, duration: 1_800), nil),
                (waiting, file("Звонок маме.m4a", hours: 0.5, duration: 640), nil),
                (diarizing, file("Круглый стол.wav", hours: 0.6, duration: 4_380), nil),
                (failed, file("Запись с диктофона.amr", hours: 30, duration: 90), nil),
                (interrupted, call("Telegram", hours: 52, duration: 780, state: .recording), nil),
                (expired, expiredMeta, zoomDoc),
            ]
        }
        for (id, meta, document) in items {
            _ = try? folder.create(meta, id: id, excludedFromBackup: true)
            if let document { try? folder.updateTranscript(id) { $0 = document } }
        }
        let queue = PreviewQueue([
            running: .transcribing(0.34), queued: .queued, preparing: .preparingModel,
            waiting: .waitingForDictation(0.58), diarizing: .diarizing(0.8), failed: .failed(.unreadable),
        ])
        let controller = TranscriptsController(folder: folder, queue: queue, voice: voice, models: {
            ModelCatalog.recognizers.prefix(2).map { (id: $0.id, title: ModelNames.display($0)) }
        })
        // «Конспект» and «Протокол встречи» on a local model of the modes; the call has its minutes.
        var modes = VoiceModeSet.defaults(VoiceModesStore.localized)
        if let clean = modes.modes.firstIndex(where: { $0.id == BuiltInMode.clean.rawValue }) {
            modes.modes[clean].refine = RefineConfig(endpoint: VoiceEndpoint.Preset.ollama.rawValue, model: "qwen2.5:7b",
                                                     prompt: "")
        }
        controller.summaries = TranscriptSummaries(modes: VoiceModesStore(preview: modes, managed: managed), folder: folder)
        if !empty {
            try? folder.saveNote("""
            # Планёрка: итоги недели

            ## Участники
            - Я
            - Собеседники

            ## Решения
            - Релиз выкатываем в **четверг**, если юристы подпишут до среды.

            ## Задачи
            - Я — отчёт по тестам до пятницы.
            - Собеседники — получить подпись юристов.

            ## Открытые вопросы
            - Кто дежурит в выходные после релиза?
            """, .minutes, for: zoom, revision: folder.transcriptRevision(zoom))
        }
        return TranscriptsFixture(controller: controller, interview: interview, zoom: zoom, running: running,
                                  failed: failed, interrupted: interrupted, expired: expired)
    }

    /// The commands the menu also has, for the window and the Recordings group: they do nothing here.
    private static func previewEntries(_ controller: TranscriptsController) -> VoiceEntries {
        VoiceEntries(call: CallRecordingController(capture: AudioCapture(), settings: controller.voice, isSupported: { true }),
                     chooseFiles: {}, openTranscripts: {})
    }

    /// The «Расшифровки» window with a recording of each kind chosen, and the Recordings group of the Voice tab.
    static func renderTranscripts(in directory: URL) {
        let size = CGSize(width: 920, height: 620)
        func shot(_ name: String, empty: Bool = false, query: String = "",
                  pane: TranscriptsController.Pane = .transcript, pick: (TranscriptsFixture) -> UUID?)
        {
            for dark in [false, true] {
                let fixture = transcriptsPreview(in: directory, name: "t-\(name)", empty: empty)
                fixture.controller.reload()
                fixture.controller.entries = previewEntries(fixture.controller)
                fixture.controller.selection = pick(fixture)
                fixture.controller.query = query
                fixture.controller.pane = pane
                let view = TranscriptsView(controller: fixture.controller)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: size, to: directory.appending(path: "transcripts-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
        shot("interview", query: "отчёт") { $0.interview }
        shot("call") { $0.zoom }
        shot("running") { $0.running }
        shot("interrupted") { $0.interrupted }
        shot("failed") { $0.failed }
        shot("audio-removed") { $0.expired }
        shot("minutes", pane: .note(.minutes)) { $0.zoom }
        shot("summary-offer", pane: .note(.summary)) { $0.interview }
        shot("empty", empty: true) { _ in nil }
        let cases: [(name: String, managed: ManagedSettings)] = [
            ("records", ManagedSettings()),
            ("records-managed", ManagedSettings(callAudioKeepDisabled: true, transcriptsBackupDisabled: true)),
        ]
        for dark in [false, true] {
            for item in cases {
                let fixture = transcriptsPreview(in: directory, name: "g-\(item.name)", managed: item.managed)
                fixture.controller.reload()
                fixture.controller.entries = previewEntries(fixture.controller)
                let view = VStack(alignment: .leading, spacing: 16) { RecordingsGroup(controller: fixture.controller) }
                    .padding(24)
                    .frame(width: 620, height: 520, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                render(view, dark: dark, size: CGSize(width: 620, height: 520),
                       to: directory.appending(path: "voice-\(item.name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
#endif
#endif
