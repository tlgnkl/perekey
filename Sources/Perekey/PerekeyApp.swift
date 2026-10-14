// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
#if PEREKEY_VOICE
import PerekeyVoice
import PerekeyVoiceCore
#endif
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
        #if DEBUG && PEREKEY_VOICE
        DebugVoiceScenario.runIfRequested()
        #endif
        #if PEREKEY_VOICE
        // `--voice-check <name>`: a hidden check of the voice layer that needs
        // the app's own permissions (VoiceCheck.swift). It exits when done.
        if let check = VoiceCheck(arguments: CommandLine.arguments) {
            Task.detached { exit(await check.run()) }
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.run()
        }
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
    #if PEREKEY_VOICE
    /// The voice settings and speech models. Lives with the app, so the
    /// network gate and the downloads do not depend on the Settings window.
    private let voiceModels: VoiceModelsController
    /// The text rules and the dictation history.
    private let voiceText: VoiceTextController
    /// The «Расшифровки» window and what it holds. The file queue and the call
    /// recorder plug into `transcripts.controller` (`queue`, `live`).
    private let transcripts: TranscriptsWindow
    /// Dictation: the hotkey, the microphone, the engines, the paste.
    private let voice: VoiceSetup
    /// "What's new: voice input", once, for someone who already uses Perekey.
    private let voiceIntro: VoiceIntroController
    /// «Записать созвон»: the microphone and the system audio to disk.
    private let callRecording: CallRecordingController
    #endif

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
        #if PEREKEY_VOICE
        let voiceModels = VoiceModelsController(settings: VoiceSettingsStore())
        self.voiceModels = voiceModels
        let voiceModes = VoiceModesStore()
        let voiceText = VoiceTextController()
        self.voiceText = voiceText
        voice = VoiceSetup(input: input, models: voiceModels, modes: voiceModes, text: voiceText, usage: usage)
        let transcriptsController = TranscriptsController(voice: voiceModels.settings, models: { [voiceModels, voiceModes] in
            let local = voiceModels.statuses.filter { $0.state == .ready && $0.entry.engine.recognizes }
                .map { (id: $0.id, title: ModelNames.display($0.entry)) }
            // As in the Voice tab: a cloud model whose server the user set up.
            let cloud = CloudSpeechModel.known.filter { model in
                voiceModes.modes.endpoint(model.endpoint).map(voiceModes.isUsable) ?? false
            }.map { (id: $0.id, title: $0.displayName + " ☁") }
            return local + cloud
        })
        transcriptsController.transcriptionModel = { [voice] in voice.files.model }
        transcriptsController.consent = { [voiceModes] in voiceModes.askConversationConsent(model: $0) }
        transcriptsController.summaries = TranscriptSummaries(modes: voiceModes, folder: transcriptsController.folder)
        voice.files.queueChanged = { [transcriptsController] in transcriptsController.queue = $0 }
        transcriptsController.queue = voice.files.queue
        let transcriptsWindow = TranscriptsWindow(controller: transcriptsController)
        transcripts = transcriptsWindow
        let callRecording = CallRecordingController(capture: voice.capture, settings: voiceModels.settings,
                                                    isSupported: { voiceModels.isSupported })
        self.callRecording = callRecording
        // The queue is made anew each time voice turns on: read at each «Стоп».
        callRecording.fileQueue = { [voice] in voice.files.queue }
        callRecording.transcriptionModel = { [voice] in voice.files.model }
        voice.files.observeQueue { [callRecording] _ in callRecording.queueChanged() }
        // «Удалить» and resume leave the recording being written alone.
        transcriptsController.live = { [callRecording] in callRecording.liveRecording.map { [$0] } ?? [] }
        callRecording.recordingsChanged = { [transcriptsController] in transcriptsController.reload() }
        #endif
        let settings = SettingsWindow(recording: recording) { section, scrollTarget in
            #if PEREKEY_VOICE
            var view = SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                                    languages: input.languages, initial: section, scrollTarget: scrollTarget)
            view.voiceController = voiceModels
            view.voiceModes = voiceModes
            view.voiceTextController = voiceText
            view.voiceTranscripts = transcriptsController
            return view
            #else
            return SettingsView(store: store, recording: recording, sources: sources, updates: updates, usage: usage,
                                languages: input.languages, initial: section, scrollTarget: scrollTarget)
            #endif
        }
        #if PEREKEY_VOICE
        let voiceSettings = voiceModels.settings
        let situation: @MainActor () -> VoiceIntro.Situation = {
            VoiceIntro.Situation(
                onboardingDone: store.settings.onboardingDone, answered: voiceSettings.settings.introAnswered,
                voiceIsOn: voiceSettings.settings.isEnabled, isSupported: voiceModels.isSupported,
                disabledByProfile: voiceSettings.managed.voiceDisabled, fileIsLocked: voiceSettings.isLocked,
                hasAccess: AXIsProcessTrusted())
        }
        let makeIntro: @MainActor () -> VoiceIntroModel = {
            let model = VoiceIntroModel(settings: voiceSettings, models: voiceModels, store: store, recording: recording)
            model.openModels = { settings.show(section: .voice, scrollTarget: "models") }
            return model
        }
        voiceIntro = VoiceIntroController(situation: situation, makeModel: makeIntro)
        onboarding.makeVoiceIntro = { VoiceIntro.offer(situation()) == .none ? nil : makeIntro() }
        voice.openVoiceSettings = { settings.show(section: .voice, scrollTarget: "models") }
        #endif
        #if PEREKEY_VOICE
        let voiceIsOn: @MainActor () -> Bool = { voiceModels.settings.isOn && voiceModels.isSupported }
        shell = MenuBarShell(sources: inputSources, store: store, pause: pause, launch: launchAtLogin,
                             input: input, recents: recents, usage: usage, onboarding: onboarding, updates: updates,
                             settings: settings) { [voice] actions in
            actions.voiceModes = VoiceModeMenu(store: voiceModes, isOn: voiceIsOn)
            actions.transcripts = TranscriptsMenu(isOn: voiceIsOn, open: { transcriptsWindow.show() })
            actions.transcribeFile = { voice.files.chooseFiles() }
            actions.canTranscribeFiles = { voice.files.queue != nil }
            actions.callRecording = callRecording
        }
        #else
        shell = MenuBarShell(sources: inputSources, store: store, pause: pause, launch: launchAtLogin,
                             input: input, recents: recents, usage: usage, onboarding: onboarding, updates: updates,
                             settings: settings)
        #endif
        super.init()
        #if PEREKEY_VOICE
        shell.dictation.menu = voiceText.menu(pasteAgain: { [voice] in voice.pasteAgain($0) })
        shell.drop = { [voice] in voice.files.transcribe($0) }
        shell.acceptsDrop = { [voice] in voice.files.acceptsDrop($0) }
        callRecording.indicator = shell.call
        // An update waits until the files in the queue are done, and for a call being recorded.
        updates.busy.add("transcription") { [voice] in voice.files.isBusy }
        updates.busy.add("recording") { [callRecording] in callRecording.isRecording }
        #endif
        ExternalControl.shared = ExternalControl(store: store, pause: pause, appModes: input.appModes, sources: inputSources)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if PEREKEY_VOICE
        voiceModels.start()
        #endif
        onboarding.showIfNeeded()
        #if PEREKEY_VOICE
        voiceIntro.showIfNeeded()
        #endif
        // After launch, so the status bar exists.
        shell.start()
        #if PEREKEY_VOICE
        // A call a crash cut off is offered for transcription; old audio goes.
        callRecording.launched()
        #endif
    }

    /// ⌘Q, logout and an update's relaunch wait while a call is recorded,
    /// until its open segments are closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if PEREKEY_VOICE
        return callRecording.shouldTerminate()
        #else
        return .terminateNow
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Counters reach the disk at most every few seconds, and here at quit.
        usage.flush()
        #if PEREKEY_VOICE
        // The history writes off the main thread: let the last one land.
        voiceText.history.flush()
        #endif
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
    /// What the menu shows of the dictation history; filled once voice is set up.
    let dictation = DictationMenuSource()
    /// The capsule's ● and time while a call is recorded.
    let call = CallIndicatorModel()
    /// Files dropped on the menu bar item; set before `start` to take them.
    var drop: (([URL]) -> Bool)?
    var acceptsDrop: (URL) -> Bool = { _ in false }

    init(sources: InputSources, store: SettingsStore, pause: PauseState, launch: LaunchAtLogin, input: InputController,
         recents: RecentCorrections, usage: UsageRecorder, onboarding: OnboardingController, updates: Updates,
         settings: SettingsWindow, extend: @escaping @MainActor (inout MenuActions) -> Void = { _ in })
    {
        self.sources = sources
        self.store = store
        self.pause = pause
        self.recents = recents
        self.onboarding = onboarding
        let reportWindow = reportWindow
        let dictation = dictation
        menu = MenuPanelController(
            sources: sources, store: store, pause: pause, launch: launch, appModes: input.appModes,
            recents: recents, usage: usage, updates: updates
        ) { menu in
            var actions = MenuActions(
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
            extend(&actions)
            #if PEREKEY_VOICE
            actions.dictation = dictation.menu
            #endif
            return actions
        }
    }

    func start() {
        guard statusItem == nil else { return }
        statusItem = StatusItemController(sources: sources, store: store, pause: pause, recents: recents, menu: menu,
                                          call: call, drop: drop, accepts: acceptsDrop)
    }
}

/// Hands the menu the recent dictations once they exist. Empty without voice.
@MainActor
final class DictationMenuSource {
    #if PEREKEY_VOICE
    var menu: DictationMenu?
    #endif
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
