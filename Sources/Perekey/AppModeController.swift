// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput

/// The app that is in front, as far as modes care.
struct FrontApp: Equatable {
    var bundleID: String
    var name: String
    var isGame: Bool
}

/// Follows the frontmost app, resolves its mode and applies it: the "off" pause
/// reason, and the app's default or remembered layout.
///
/// Perekey's own windows never count as the frontmost app, so the menu and the
/// Settings window keep talking about the app the user came from.
@MainActor
@Observable
final class AppModeController {
    /// The frontmost app other than Perekey.
    private(set) var frontmost: FrontApp?

    /// The mode in force in `frontmost`; `.auto` when there is none.
    /// The autoswitch decision reads this: `.auto` fixes by itself, `.manualOnly`
    /// only on the user's command, `.off` never (the pause card is shown then).
    var mode: AppMode {
        if isDemoFront { return .auto }
        guard let frontmost else { return .auto }
        return store.settings.effectiveMode(bundleID: frontmost.bundleID, isGame: frontmost.isGame)
    }

    /// The onboarding demo is on screen: Perekey's own window acts as an app in
    /// «Auto» mode, whatever app the user came from (a terminal, a game).
    var onboardingDemo = false {
        didSet { if onboardingDemo != oldValue { perekeyIsFront = onboardingDemo && NSApp.isActive } }
    }
    /// Perekey itself is the active app (tracked only while the demo shows).
    private(set) var perekeyIsFront = false

    /// The demo window is in front: only then it acts as an app in «Auto» mode.
    var isDemoFront: Bool { onboardingDemo && perekeyIsFront }

    /// The demo's own words: the only ones whose undo is not learned.
    static func isDemoWord(_ word: String) -> Bool { word == "ghbdtn" || word == "привет" }

    @ObservationIgnored private let sources: InputSources
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let pause: PauseState
    @ObservationIgnored private var lastLayouts: [String: LayoutID] = [:]
    @ObservationIgnored private var appliedOff = false
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
    /// Site rules in browsers; they override the browser's app rule.
    @ObservationIgnored private var sites: SiteLayoutController?

    init(sources: InputSources, store: SettingsStore, pause: PauseState, live: Bool = true) {
        self.sources = sources
        self.store = store
        self.pause = pause
        guard live else { return }
        sites = SiteLayoutController(sources: sources, store: store)
        pause.onTurnOnHere = { [weak self] in self?.turnOnHere() }
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        })
        activated(NSWorkspace.shared.frontmostApplication, selectLayout: false)
        observeRules()
    }

    #if DEBUG
    /// Snapshot helper: a fixed frontmost app, no observers.
    func freeze(frontmost app: FrontApp?) { frontmost = app }
    #endif

    /// Switches the frontmost app between "off" and "auto" (the menu row).
    func setOff(_ off: Bool) {
        guard let frontmost else { return }
        store.setMode(off ? .off : .auto, for: frontmost.bundleID)
    }

    /// Sets the mode of the frontmost app (`perekey://mode`, AppleScript).
    func setMode(_ mode: AppMode) {
        guard let frontmost else { return }
        store.setMode(mode, for: frontmost.bundleID)
    }

    private func turnOnHere() {
        guard let frontmost else { return }
        store.setMode(.auto, for: frontmost.bundleID)
    }

    private func activated(_ app: NSRunningApplication?, selectLayout: Bool = true) {
        if onboardingDemo, let app { perekeyIsFront = app.processIdentifier == getpid() }
        guard let app, app.processIdentifier != getpid(), let bundleID = app.bundleIdentifier else { return }
        guard bundleID != frontmost?.bundleID else { return }
        if let left = frontmost, let layout = sources.currentLayout { lastLayouts[left.bundleID] = layout }
        sites?.appLeft()
        let category = app.bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        frontmost = FrontApp(
            bundleID: bundleID,
            name: app.localizedName ?? bundleID,
            isGame: AppModes.isGame(category: category)
        )
        applyPause()
        if selectLayout { selectLayoutForFrontmost() }
    }

    private func applyPause() {
        guard let frontmost else { return }
        let off = mode == .off
        if off {
            pause.setAppOff(app: frontmost.name)
        } else if appliedOff {
            pause.setAppOff(app: nil)
        }
        appliedOff = off
    }

    private func selectLayoutForFrontmost() {
        guard let frontmost, let rule = store.settings.apps[frontmost.bundleID] else { return }
        let target = rule.defaultLayout ?? (rule.rememberLastLayout ? lastLayouts[frontmost.bundleID] : nil)
        if let target, target != sources.currentLayout { sources.select(target) }
    }

    /// A rule edited in Settings or the menu applies at once, to the app in front.
    private func observeRules() {
        withObservationTracking {
            _ = store.settings.apps
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyPause()
                self?.observeRules()
            }
        }
    }
}

extension SettingsStore {
    /// Sets one app's mode, keeping its layout fields.
    func setMode(_ mode: AppMode, for bundleID: String) {
        updateRule(for: bundleID) { $0.mode = mode }
    }

    /// Edits one app's rule. A new rule starts from `base`, the mode the app has now.
    func updateRule(for bundleID: String, base: AppMode? = nil, _ change: (inout AppRule) -> Void) {
        update { settings in
            var rule = settings.apps[bundleID] ?? AppRule(
                mode: base ?? AppModes.builtInMode(bundleID: bundleID) ?? .auto
            )
            change(&rule)
            settings.apps[bundleID] = rule
        }
    }

    /// Drops the rule; the built-in default applies again.
    func resetRule(for bundleID: String) {
        update { $0.apps[bundleID] = nil }
    }
}

extension AppMode {
    var title: LocalizedStringResource {
        switch self {
        case .auto: LocalizedStringResource("Auto")
        case .manualOnly: LocalizedStringResource("Manual only")
        case .off: LocalizedStringResource("Off")
        }
    }
}

/// Names and icons of apps by bundle ID or URL.
@MainActor
enum AppInfo {
    static func url(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func name(at url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(at url: URL?) -> NSImage {
        guard let url else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func isGame(at url: URL) -> Bool {
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        return AppModes.isGame(category: category)
    }
}
