// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import os
import PerekeyCore
import PerekeyInput

/// Runs the commands that come from outside: `perekey://` links and AppleScript.
///
/// Both doors end in `perform(_:)`, which only calls what the menu calls. The
/// grammar and its limits are in `ControlCommand`. No managed key (see
/// docs/managed-preferences.md) locks pause, autoswitch or modes, so none is checked.
@MainActor
final class ExternalControl {
    /// The one instance, set by `PerekeyApp` once the models exist. Scripting commands
    /// are created by Cocoa and reach the app through it.
    static var shared: ExternalControl?

    private let store: SettingsStore
    private let pause: PauseState
    private let appModes: AppModeController
    private let sources: InputSources
    private let log = Logger(subsystem: "app.perekey", category: "control")

    init(store: SettingsStore, pause: PauseState, appModes: AppModeController, sources: InputSources) {
        self.store = store
        self.pause = pause
        self.appModes = appModes
        self.sources = sources
    }

    // MARK: URL

    func open(_ urls: [URL]) {
        for url in urls {
            guard let command = ControlCommand.parse(url) else {
                // The URL can hold anything a page put there: log only that it was refused.
                log.info("Ignored a perekey:// URL that is not a known command")
                continue
            }
            perform(command)
        }
    }

    func perform(_ command: ControlCommand) {
        switch command {
        case .pause(let minutes): pause.pause(minutes: minutes)
        case .resume: pause.resumeTimed()
        case .autoswitch(let on): setAutoswitch(on ?? !store.settings.autoswitch)
        case .mode(let mode): setMode(mode)
        }
    }

    // MARK: State, for AppleScript

    var isPaused: Bool { pause.current != nil }
    var autoswitchIsOn: Bool { store.settings.autoswitch }
    var layoutName: String { sources.currentLayout.map { sources.name(of: $0) } ?? "" }

    var modeName: String {
        appModes.mode.scriptName
    }

    func setAutoswitch(_ on: Bool) {
        store.update { $0.autoswitch = on }
    }

    /// The mode of the app in front. Does nothing when there is none.
    func setMode(_ mode: AppMode) {
        appModes.setMode(mode)
    }
}

// MARK: AppleScript (Support/Perekey.sdef)

private extension AppMode {
    /// The word in URLs and scripts: `manualOnly` is `manual`.
    var scriptName: String {
        switch self {
        case .auto: "auto"
        case .manualOnly: "manual"
        case .off: "off"
        }
    }
}

/// The scripting properties of the application. Cocoa reads and writes them by key;
/// scripting runs on the main thread.
extension NSApplication {
    @objc var perekeyLayoutName: String {
        MainActor.assumeIsolated { ExternalControl.shared?.layoutName ?? "" }
    }

    @objc var perekeyPaused: Bool {
        MainActor.assumeIsolated { ExternalControl.shared?.isPaused ?? false }
    }

    @objc var perekeyAutoswitch: Bool {
        get { MainActor.assumeIsolated { ExternalControl.shared?.autoswitchIsOn ?? false } }
        set { MainActor.assumeIsolated { ExternalControl.shared?.setAutoswitch(newValue) } }
    }

    @objc var perekeyAppMode: String {
        get { MainActor.assumeIsolated { ExternalControl.shared?.modeName ?? "auto" } }
        set {
            // The same words as the URL; anything else is ignored.
            let mode = [AppMode.auto, .manualOnly, .off].first { $0.scriptName == newValue }
            if let mode { MainActor.assumeIsolated { ExternalControl.shared?.setMode(mode) } }
        }
    }
}

/// `pause [for minutes N]`
@objc(PerekeyPauseCommand)
final class PauseScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let minutes = (evaluatedArguments?["minutes"] as? Int) ?? ControlCommand.defaultPauseMinutes
        guard ControlCommand.pauseMinutesRange.contains(minutes) else {
            scriptErrorNumber = Int(errAEWrongDataType)
            scriptErrorString = "Minutes must be from 1 to 1440."
            return nil
        }
        MainActor.assumeIsolated { ExternalControl.shared?.perform(.pause(minutes: minutes)) }
        return nil
    }
}

/// `resume`
@objc(PerekeyResumeCommand)
final class ResumeScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { ExternalControl.shared?.perform(.resume) }
        return nil
    }
}
