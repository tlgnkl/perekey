// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import IOKit
import Observation

/// Secure Input ("Secure Keyboard Entry"): while it is on, the system keeps key
/// presses away from event taps.
public enum SecureInput {
    /// Whether some process has Secure Input on in this login session.
    /// HIToolbox reads a flag; the spike called it every 2 s without cost.
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }

    /// PID of the process that turned Secure Input on, best effort.
    ///
    /// There is no public API for it. This reads the undocumented
    /// `kCGSSessionSecureInputPID` key of the `IOConsoleUsers` registry property
    /// through public IOKit, as Alfred and Keyboard Maestro do. It is an IPC to
    /// the kernel: call it on the main thread or a queue, not in the tap callback.
    /// The key may be stale while Secure Input is off; check `isEnabled` first.
    public static func ownerPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(),
            let sessions = value as? [[String: Any]]
        else { return nil }
        return ownerPID(inConsoleUsers: sessions, uid: getuid())
    }

    /// Picks this user's session out of `IOConsoleUsers` and returns its
    /// Secure Input PID. With fast user switching the array holds one entry per
    /// logged-in user. A session of `uid` wins, the one on the console first;
    /// without a `uid` match, the session on the console. PID 0 means "none".
    static func ownerPID(inConsoleUsers sessions: [[String: Any]], uid: uid_t) -> pid_t? {
        func number(_ session: [String: Any], _ key: String) -> NSNumber? { session[key] as? NSNumber }
        func isOnConsole(_ session: [String: Any]) -> Bool { number(session, "kCGSSessionOnConsoleKey")?.boolValue ?? false }

        let mine = sessions.filter { number($0, "kCGSSessionUserIDKey")?.uint32Value == uid }
        let session = mine.first(where: isOnConsole) ?? mine.first ?? sessions.first(where: isOnConsole)
        guard let pid = session.flatMap({ number($0, "kCGSSessionSecureInputPID") })?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    /// Who holds Secure Input. Main thread: `NSRunningApplication` is AppKit.
    @MainActor
    public static func owner(pid: pid_t?) -> SecureInputOwner {
        guard let pid, pid > 0 else { return .unknown }
        let app = NSRunningApplication(processIdentifier: pid)
        let name = app?.localizedName ?? processName(pid)
        if app?.bundleIdentifier == "com.apple.loginwindow" || name == "loginwindow" {
            return .loginWindow(pid: pid)
        }
        guard let name else { return .unknown }
        return .process(pid: pid, name: name, bundleID: app?.bundleIdentifier)
    }

    /// The executable name of a process that is not an app, e.g. a daemon.
    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// The process that turned Secure Input on.
public enum SecureInputOwner: Hashable, Sendable {
    /// No PID in the registry, or the process is gone.
    case unknown
    /// The screen is locked, or the login window kept Secure Input after an
    /// unlock: a known macOS bug that lasts until logout. Not an app the user
    /// can quit, so the UI says so instead of naming it.
    case loginWindow(pid: pid_t)
    case process(pid: pid_t, name: String, bundleID: String?)

    /// The name for the warning, e.g. "Terminal"; nil when there is no app to name.
    public var name: String? {
        if case let .process(_, name, _) = self { name } else { nil }
    }
}

/// Secure Input state for the UI and for the tap, kept current without polling.
///
/// There is no notification for Secure Input, and a timer would break the
/// idle budget (about 0 % CPU, docs/PLAN.md "Потоки"). So the monitor reads the
/// state when something that may change it happens: an app switch, wake,
/// session switch, screen lock and unlock, and whenever someone calls
/// `refresh()`. The wiring should call `refresh()` when the tap sees a modifier
/// change (key presses do not reach the tap under Secure Input, modifier
/// changes do), when a key press arrives while `isOn` is true (Secure Input
/// must have ended), and when `FocusObserver` reports a new focus (a password
/// field got focus).
///
/// Why the detector must be off while Secure Input is on: the tap then sees a
/// password's Shift presses but not its letters, so every capital letter looks
/// like a lone Shift tap and would switch the layout mid-password. The tap
/// should not wait for this main-thread monitor to learn that: it can read
/// `SecureInput.isEnabled` itself on each modifier event and feed
/// `.secureInputChanged` to the core before the event, so the first capital
/// letter is already safe. This monitor then serves the UI (menu capsule,
/// owner name) and catches changes no key event announces.
@MainActor
@Observable
public final class SecureInputMonitor {
    public private(set) var isOn: Bool
    /// Nil while Secure Input is off.
    public private(set) var owner: SecureInputOwner?

    /// The owner's name for the warning; nil when off or unknown.
    public var ownerName: String? { owner?.name }

    /// Called when `isOn` changes, after the properties are updated.
    @ObservationIgnored public var onChange: (@MainActor (Bool) -> Void)?

    @ObservationIgnored private var ownerPID: pid_t?
    @ObservationIgnored private var observers: NotificationTokens?
    @ObservationIgnored private let readIsOn: @MainActor () -> Bool
    @ObservationIgnored private let readOwnerPID: @MainActor () -> pid_t?

    public convenience init() {
        self.init(isOn: { SecureInput.isEnabled }, ownerPID: { SecureInput.ownerPID() }, observe: true)
    }

    /// The closures replace the system in tests.
    init(isOn readIsOn: @escaping @MainActor () -> Bool, ownerPID readOwnerPID: @escaping @MainActor () -> pid_t?,
         observe: Bool)
    {
        self.readIsOn = readIsOn
        self.readOwnerPID = readOwnerPID
        let on = readIsOn()
        let pid = on ? readOwnerPID() : nil
        isOn = on
        ownerPID = pid
        owner = on ? SecureInput.owner(pid: pid) : nil
        if observe {
            observers = NotificationTokens.observeSessionChanges { [weak self] in self?.refresh() }
        }
    }

    /// Reads the state again. Cheap when nothing changed; safe to call often.
    public func refresh() {
        let on = readIsOn()
        // The registry is read only while on, the app looked up only when the PID
        // changes: refresh runs on modifier presses.
        let pid = on ? readOwnerPID() : nil
        if pid != ownerPID || on != isOn {
            ownerPID = pid
            let newOwner = on ? SecureInput.owner(pid: pid) : nil
            if newOwner != owner { owner = newOwner }
        }
        guard on != isOn else { return }
        isOn = on
        onChange?(on)
    }
}

/// Notification observers that unregister in their own `deinit`: a
/// nonisolated `deinit` of a main-actor class cannot touch its state.
final class NotificationTokens: NSObject, @unchecked Sendable {
    // Mutated only while the owner sets it up, before the object is shared.
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var distributedHandler: (@MainActor () -> Void)?

    /// `queue: nil` delivers on the posting thread; AppKit posts workspace
    /// notifications on the main one.
    func observe(_ center: NotificationCenter, _ names: [Notification.Name],
                 _ block: @escaping @Sendable (Notification) -> Void)
    {
        for name in names {
            tokens.append((center, center.addObserver(forName: name, object: nil, queue: nil, using: block)))
        }
    }

    /// Distributed notifications with `.deliverImmediately`: a menu bar app is
    /// almost never active, and AppKit holds them back from inactive apps
    /// otherwise. Only the selector API offers it. One handler per object.
    @MainActor
    func observeDistributed(_ names: [String], _ handler: @escaping @MainActor () -> Void) {
        distributedHandler = handler
        for name in names {
            DistributedNotificationCenter.default().addObserver(
                self, selector: #selector(distributed), name: Notification.Name(name),
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
    }

    /// App activation, wake, fast user switching, and screen lock and unlock.
    @MainActor
    static func observeSessionChanges(_ handler: @escaping @MainActor () -> Void) -> NotificationTokens {
        let observer = NotificationTokens()
        observer.observe(NSWorkspace.shared.notificationCenter,
                         [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
                          NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                          NSWorkspace.sessionDidResignActiveNotification])
        { _ in
            MainActor.assumeIsolated { handler() }
        }
        // Undocumented but long-standing; loginwindow takes Secure Input while
        // the screen is locked.
        observer.observeDistributed(["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"], handler)
        return observer
    }

    // Distributed notifications arrive on the main run loop.
    @objc private func distributed(_: Notification) {
        MainActor.assumeIsolated { distributedHandler?() }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
