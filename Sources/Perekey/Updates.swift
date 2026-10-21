// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation
import Observation
import os
import PerekeyCore
import Sparkle

/// Reads the keys a configuration profile forces in `app.perekey.Perekey`.
enum ManagedPreferences {
    static func read() -> ManagedSettings {
        let domain = ManagedSettings.domain as CFString
        return ManagedSettings { key in
            guard CFPreferencesAppValueIsForced(key as CFString, domain) else { return nil }
            return CFPreferencesCopyAppValue(key as CFString, domain)
        }
    }
}

/// Sparkle 2 behind the update settings: the switch, "Check Now", the last
/// check date and the gentle reminder in the menu.
///
/// Privacy (docs/PLAN.md, «Приватность»): the only request is a GET of
/// `SUFeedURL` with Sparkle's user agent. No system profile, no feed
/// parameters, no identifiers. The updater is created only when the build is
/// configured and no profile forbids updates, and it starts only when automatic
/// checks are on or the user asks for a check. Stopped, it makes no requests.
@MainActor
@Observable
final class Updates: NSObject {
    let managed: ManagedSettings
    /// Info.plist has a feed and a real public key. False in development builds.
    let isConfigured: Bool
    private(set) var lastCheck: Date?
    /// A scheduled check found this version, and the menu shows it instead of an alert.
    private(set) var pendingVersion: String?

    /// Work a relaunch for an update would cut off: Sparkle waits while it goes on.
    @ObservationIgnored let busy = RelaunchBlockers()
    private static let log = Logger(subsystem: "app.perekey", category: "updates")
    /// The wait for `busy` before an update's relaunch.
    @ObservationIgnored private var postponed: Task<Void, Never>?
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var started = false

    init(store: SettingsStore, bundle: Bundle = .main, managed: ManagedSettings = ManagedPreferences.read()) {
        self.store = store
        self.managed = managed
        isConfigured = UpdateFeed.isConfigured(
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        super.init()
        guard policy.state != .managedOff, policy.state != .notConfigured else { return }
        // Creating the controller does not start it and makes no requests.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self,
                                                      userDriverDelegate: self)
        controller.updater.sendsSystemProfile = false
        self.controller = controller
        lastCheck = controller.updater.lastUpdateCheckDate
        if policy.startsAtLaunch { start(automatic: true) }
    }

    #if DEBUG
    /// Snapshot helper: a fixed state, no Sparkle.
    init(store: SettingsStore, preview managed: ManagedSettings, configured: Bool, lastCheck: Date?,
         pendingVersion: String? = nil) {
        self.store = store
        self.managed = managed
        isConfigured = configured
        self.lastCheck = lastCheck
        self.pendingVersion = pendingVersion
        super.init()
    }
    #endif

    var policy: UpdatePolicy {
        UpdatePolicy(configured: isConfigured, managed: managed, checkAutomatically: store.settings.checkForUpdates)
    }

    /// What the switch shows: off and locked when a profile forbids updates.
    var checksAutomatically: Bool {
        policy.state == .managedOff ? false : store.settings.checkForUpdates
    }

    func setChecksAutomatically(_ on: Bool) {
        guard !policy.isLocked else { return }
        store.update { $0.checkForUpdates = on }
        guard let controller else { return }
        if on {
            start(automatic: true)
        } else if started {
            // Cancels the scheduled check; Sparkle stays idle until the user asks.
            controller.updater.automaticallyChecksForUpdates = false
        }
    }

    /// "Check Now" and "Check for Updates…": the user asked, so this may reach
    /// the network even with automatic checks off. Never with a profile against it.
    func checkNow() {
        guard policy.canCheckNow, let controller else { return }
        start(automatic: store.settings.checkForUpdates)
        controller.checkForUpdates(nil)
    }

    private func start(automatic: Bool) {
        guard let controller else { return }
        // Set before starting, so a stopped-by-the-user updater never schedules a check.
        controller.updater.automaticallyChecksForUpdates = automatic
        controller.updater.automaticallyDownloadsUpdates = false
        if !started {
            controller.startUpdater()
            started = true
        }
    }
}

extension Updates: SPUUpdaterDelegate {
    /// No system profile, whatever the defaults say.
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    /// No extra query parameters: the request is the bare feed address.
    nonisolated func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool)
        -> [[String: String]] { [] }

    /// No update when every release in the feed is older than the installed
    /// version; otherwise Sparkle picks, with its own filters. Sparkle compares
    /// build numbers only, and a local build has build 0, so it would offer
    /// 0.1.1 over 0.2.0. CI build numbers grow with each release, so when a
    /// release is not older, Sparkle's pick is not older either.
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        let installed = updater.hostBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let allOlder = appcast.items.allSatisfy { UpdateFeed.isOlder($0.displayVersionString, than: installed) }
        return allOlder ? .empty() : nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastCheck = updater.lastUpdateCheckDate
    }

    /// A source that never lets go does not hold an update for good.
    static let longestPostponement: Duration = .seconds(24 * 3600)

    /// The update installs once `busy` is over, or after a day at most. A
    /// new call replaces the wait of the one before: its handler is the one
    /// Sparkle now expects, and it is called once.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool
    {
        postponed?.cancel()
        postponed = nil
        guard busy.isBusy else { return false }
        let busy = self.busy
        postponed = Task { @MainActor in
            let deadline = ContinuousClock.now + Self.longestPostponement
            while busy.isBusy {
                if ContinuousClock.now >= deadline {
                    Self.log.warning("Update relaunch postponed for a day; installing while busy")
                    break
                }
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}

/// Gentle reminders (sparkle-project.org/documentation/gentle-reminders): a menu
/// bar app has no Dock icon, so a scheduled alert would pop up behind other
/// windows. A found update shows in the menu instead, unless Sparkle would show
/// it in immediate focus (right after launch).
extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}

/// What keeps an update from relaunching Perekey: work a relaunch would cut
/// off. Each part adds its source once, by name — the file queue
/// ("transcription"), the call recorder ("recording") — and the Sparkle
/// delegate asks only `isBusy`.
@MainActor
final class RelaunchBlockers {
    private var sources: [String: @MainActor () -> Bool] = [:]

    /// Adds or replaces the source under `name`.
    func add(_ name: String, _ isBusy: @escaping @MainActor () -> Bool) {
        sources[name] = isBusy
    }

    var isBusy: Bool { sources.values.contains { $0() } }
}
