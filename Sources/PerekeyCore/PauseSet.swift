// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why Perekey is not acting right now.
public enum PauseReason: Hashable, Sendable {
    /// The user paused for a while. The deadline is a wall-clock date, so time
    /// spent asleep counts.
    case timed(until: Date)
    /// Some app turned Secure Input on; macOS hides keystrokes from everyone.
    case secureInput(owner: String?)
    /// The focus is in a password field.
    case passwordField
    /// The program's mode is "off" (or the program is on the exclusion list).
    case appOff(app: String)
}

/// Every active pause reason at once, and the one to show.
///
/// Pure value logic with the time passed in, so it is unit-tested. The app
/// target wraps it in an observable object and schedules one wake-up at
/// `nextDeadline`.
public struct PauseSet: Equatable, Sendable {
    public private(set) var timedUntil: Date?
    public private(set) var secureInput = false
    public private(set) var secureInputOwner: String?
    public private(set) var passwordField = false
    public private(set) var appOffApp: String?

    public init() {}

    public mutating func pause(until deadline: Date) { timedUntil = deadline }
    public mutating func resumeTimed() { timedUntil = nil }

    public mutating func setSecureInput(_ on: Bool, owner: String? = nil) {
        secureInput = on
        secureInputOwner = on ? owner : nil
    }

    public mutating func setPasswordField(_ on: Bool) { passwordField = on }

    /// `nil` clears it.
    public mutating func setAppOff(app: String?) { appOffApp = app }

    /// Drops a timed pause whose deadline has passed. Returns true if it did.
    @discardableResult
    public mutating func expire(at now: Date) -> Bool {
        guard let timedUntil, timedUntil <= now else { return false }
        self.timedUntil = nil
        return true
    }

    /// Active reasons, most important first.
    ///
    /// Priority: password field, Secure Input, timed pause, app off. The first
    /// two are facts about this very moment that the user cannot change from the
    /// menu, so they explain the capsule best. The timed pause is the user's own
    /// fresh action and outranks the standing "off in this app" setting.
    public func reasons(at now: Date) -> [PauseReason] {
        var result: [PauseReason] = []
        if passwordField { result.append(.passwordField) }
        if secureInput { result.append(.secureInput(owner: secureInputOwner)) }
        if let timedUntil, timedUntil > now { result.append(.timed(until: timedUntil)) }
        if let appOffApp { result.append(.appOff(app: appOffApp)) }
        return result
    }

    /// The reason the capsule and the menu card show.
    public func top(at now: Date) -> PauseReason? { reasons(at: now).first }

    /// When the state changes by itself. Only a timed pause does.
    public var nextDeadline: Date? { timedUntil }

    /// Whole minutes left, rounded up, never below 1 while the pause lasts.
    public static func minutesLeft(until deadline: Date, at now: Date) -> Int {
        max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
