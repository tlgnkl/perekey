// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore

/// The pause reasons that are active, observable by the capsule and the menu.
///
/// The timed pause lives on the wall clock (`Date`), so it survives sleep. There
/// is no ticking timer: one `Task.sleep` wakes at the deadline, and a wake from
/// system sleep re-checks, because the sleep clock does not count time asleep.
/// `now` moves only while the menu is open (`tick()`), so the "minutes left"
/// text is stale in the closed menu bar capsule by design.
///
/// Other lanes call `setSecureInput`, `setPasswordField` and `setAppOff`.
@MainActor
@Observable
final class PauseState {
    private(set) var pauses = PauseSet()
    /// The time the views render against. Updated by `tick()` and every change.
    private(set) var now = Date()

    /// Runs when the user taps "Turn on here" on an "off in this app" card.
    /// The app-mode lane sets it.
    @ObservationIgnored var onTurnOnHere: (@MainActor () -> Void)?

    @ObservationIgnored private var wakeUp: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The reason to show, or `nil` when Perekey is working.
    var current: PauseReason? { pauses.top(at: now) }

    var isTimedPauseActive: Bool {
        if case .timed = current { return true }
        guard let until = pauses.timedUntil else { return false }
        return until > now
    }

    // MARK: Timed pause (the menu)

    func pauseForOneHour() {
        pauses.pause(until: Date().addingTimeInterval(3600))
        refresh()
    }

    func resumeTimed() {
        pauses.resumeTimed()
        refresh()
    }

    // MARK: Sources other lanes feed

    func setSecureInput(_ on: Bool, owner: String? = nil) {
        pauses.setSecureInput(on, owner: owner)
        refresh()
    }

    func setPasswordField(_ on: Bool) {
        pauses.setPasswordField(on)
        refresh()
    }

    /// `nil` clears the "off here" reason.
    func setAppOff(app: String?) {
        pauses.setAppOff(app: app)
        refresh()
    }

    // MARK: Time

    /// The menu calls this while it is open, to refresh the minutes.
    func tick() { refresh() }

    /// Brings `now` up to date, drops an expired pause and re-arms the single wake-up.
    private func refresh() {
        now = Date()
        pauses.expire(at: now)
        wakeUp?.cancel()
        wakeUp = nil
        guard let deadline = pauses.nextDeadline else { return }
        wakeUp = Task { [weak self] in
            let wait = deadline.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    #if DEBUG
    /// Snapshot helper: a state frozen at `now`, with no wake-up.
    convenience init(frozen pauses: PauseSet, now: Date) {
        self.init()
        self.pauses = pauses
        self.now = now
    }
    #endif
}
