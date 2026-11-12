// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The guard in front of every key the bench posts into a real app
/// (docs/eval.md, «Настоящая программа»). When the screen is locked, the
/// events go to the password field of the login window; when a person types
/// or moves the mouse, the bench types into their work. In both cases it
/// stops before it posts another key.
///
/// The system is read through a `Probe`, so a test replaces it.
public struct InputGuard {
    /// What the guard reads of the machine. Every number is in seconds.
    public struct Probe {
        /// `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`, and true as well when
        /// there is no session or it is not on the console (fast user switching).
        public var screenLocked: () -> Bool
        /// `HIDIdleTime` of `IOHIDSystem`: since the last input of any kind, the bench's own included.
        /// Nil when the machine does not say.
        public var idleSeconds: () -> Double?
        /// The bundle id of the app in front.
        public var frontmostApp: () -> String?
        /// A clock that never goes back.
        public var now: () -> Double

        public init(screenLocked: @escaping () -> Bool, idleSeconds: @escaping () -> Double?,
                    frontmostApp: @escaping () -> String?, now: @escaping () -> Double)
        {
            self.screenLocked = screenLocked
            self.idleSeconds = idleSeconds
            self.frontmostApp = frontmostApp
            self.now = now
        }
    }

    public struct Options: Sendable {
        /// The person must be away this long before the first key. The plan names 10 s (the
        /// brief of lane E9); the bench is local and slow, so the number is cheap to keep.
        public var quietSeconds = 10.0
        /// The bench's own keys reset `HIDIdleTime` too, and so do the retype keys Perekey posts
        /// after them. After its own key the idle time must be at least the time since that key, less
        /// this slack for the two clocks and for a retype that comes late: a smaller one means somebody
        /// else typed or moved the mouse after it. A guess; a retype takes milliseconds, a late one
        /// well under a second. Too small a number stops a good run (safe), too big one sees a person
        /// later.
        public var ownSlack = 1.0

        public init() {}
    }

    /// Why the bench stops. `exitCode` is the status of `perekey-e2e play`.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case screenLocked
        case idleUnknown
        case humanActive(idle: Double)
        case wrongApp(expected: String, actual: String?)

        public var exitCode: Int32 {
            switch self {
            case .screenLocked: 3
            case .idleUnknown, .humanActive: 4
            case .wrongApp: 5
            }
        }

        public var description: String {
            switch self {
            case .screenLocked:
                "the screen is locked: the keys would go to the password field of the login window; no key was posted"
            case .idleUnknown:
                "the machine does not say when the keyboard or the mouse was last used; no key was posted"
            case let .humanActive(idle):
                "someone used the keyboard or the mouse \(String(format: "%.1f", idle)) s ago; stopped before the next key"
            case let .wrongApp(expected, actual):
                "\(expected) is not in front (\(actual ?? "no app")); stopped before the next key"
            }
        }
    }

    public let probe: Probe
    public let options: Options
    /// The time of the last key the bench posted; nil before the first.
    private var lastPost: Double?

    public init(probe: Probe, options: Options = Options()) {
        self.probe = probe
        self.options = options
    }

    /// Throws a `Refusal` when a key must not be posted now. Cheap: call it before every event.
    public mutating func check(app: String) throws {
        if probe.screenLocked() { throw Refusal.screenLocked }
        guard let idle = probe.idleSeconds() else { throw Refusal.idleUnknown }
        if let lastPost {
            if idle < probe.now() - lastPost - options.ownSlack { throw Refusal.humanActive(idle: idle) }
        } else if idle < options.quietSeconds {
            throw Refusal.humanActive(idle: idle)
        }
        let front = probe.frontmostApp()
        if front != app { throw Refusal.wrongApp(expected: app, actual: front) }
    }

    /// The bench posted a key now.
    public mutating func posted() {
        lastPost = probe.now()
    }
}
