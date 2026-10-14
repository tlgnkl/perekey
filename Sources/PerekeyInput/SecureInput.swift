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
    /// More receivers of the same change, after `onChange`; see `addListener`.
    @ObservationIgnored private var listeners: [UUID: @MainActor (Bool) -> Void] = [:]

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
        for listener in listeners.values { listener(on) }
    }

    /// Calls `listener` on every change of `isOn`, as `onChange`; for a second
    /// receiver such as dictation. Remove it with the returned token.
    public func addListener(_ listener: @escaping @MainActor (Bool) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = listener
        return token
    }

    public func removeListener(_ token: UUID) {
        listeners[token] = nil
    }
}

/// Secure Input rules for dictation.
///
/// - Secure Input on: dictation does not start (`allowsStart`). The tap sees no
///   key presses then and `InputMachine` passes modifier changes before the
///   voice trigger, so the trigger stays quiet by itself; this is for any
///   other way to start.
/// - Secure Input comes on during a session (a password field got focus):
///   `onStop` tells the session to stop and transcribe what it has. The paste
///   then refuses by itself (`TextPaster`, `.secureField`).
/// - Esc does not reach the tap under Secure Input. While a session runs with
///   Secure Input on and `onEscape` is set, Esc is a Carbon hot key instead,
///   which the system still delivers; it is released as soon as either ends.
///
/// No key event announces Secure Input, so while a session runs the monitor
/// is read every `pollInterval`. The timer lives only inside a session: idle
/// CPU stays at 0.
@MainActor
public final class DictationSecureInput {
    public static let pollInterval: Duration = .milliseconds(250)

    /// Secure Input came on during a session: stop recording, transcribe.
    /// Called once per session.
    public var onStop: (@MainActor () -> Void)?
    /// Esc was pressed under Secure Input during a session: cancel. Nil keeps
    /// Esc unregistered.
    public var onEscape: (@MainActor () -> Void)? {
        didSet { updateEscape() }
    }

    public private(set) var isSessionActive = false

    private let monitor: SecureInputMonitor
    private let escape: any EscapeHotKey
    private let pollInterval: Duration
    private var listener: UUID?
    private var poll: Task<Void, Never>?
    private var stopSent = false

    public convenience init(monitor: SecureInputMonitor) {
        self.init(monitor: monitor, escape: CarbonEscapeHotKey(), pollInterval: Self.pollInterval)
    }

    init(monitor: SecureInputMonitor, escape: any EscapeHotKey, pollInterval: Duration) {
        self.monitor = monitor
        self.escape = escape
        self.pollInterval = pollInterval
    }

    /// Whether a dictation may start now. Reads the state first.
    public var allowsStart: Bool {
        monitor.refresh()
        return !monitor.isOn
    }

    /// A session started: watch Secure Input until `sessionEnded()`.
    public func sessionBegan() {
        guard !isSessionActive else { return }
        isSessionActive = true
        stopSent = false
        listener = monitor.addListener { [weak self] on in self?.secureInputChanged(on) }
        poll = Task { [weak self, monitor, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, self != nil else { return }
                monitor.refresh()
            }
        }
        monitor.refresh()
        // Already on when the session began (started by other means than the tap).
        if monitor.isOn { secureInputChanged(true) }
    }

    /// The session ended, pasted or not: stop watching, release Esc.
    public func sessionEnded() {
        guard isSessionActive else { return }
        isSessionActive = false
        poll?.cancel()
        poll = nil
        if let listener { monitor.removeListener(listener) }
        listener = nil
        updateEscape()
    }

    private func secureInputChanged(_ on: Bool) {
        guard isSessionActive else { return }
        updateEscape()
        if on, !stopSent {
            stopSent = true
            onStop?()
        }
    }

    private func updateEscape() {
        if isSessionActive, monitor.isOn, let onEscape {
            escape.register(onEscape)
        } else {
            escape.unregister()
        }
    }
}

/// A global Esc while the tap cannot see it.
@MainActor
public protocol EscapeHotKey: AnyObject {
    /// Registers Esc, or replaces the handler if it is registered already.
    func register(_ onPress: @escaping @MainActor () -> Void)
    /// Does nothing if not registered.
    func unregister()
}

/// Esc as a Carbon hot key: Secure Input keeps key presses from event taps,
/// not from `RegisterEventHotKey`. Held only for a moment: while registered,
/// Esc goes to Perekey and no other app.
@MainActor
public final class CarbonEscapeHotKey: EscapeHotKey {
    private static let signature: OSType = 0x5052_4B45 // "PRKE"

    // Touched by the nonisolated `deinit` as well, after the last main-actor use.
    private nonisolated(unsafe) var hotKey: EventHotKeyRef?
    private nonisolated(unsafe) var handler: EventHandlerRef?
    private var onPress: (@MainActor () -> Void)?

    public init() {}

    public var isRegistered: Bool { hotKey != nil }

    public func register(_ onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
        guard hotKey == nil else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == CarbonEscapeHotKey.signature
                else { return OSStatus(eventNotHandledErr) }
                // Carbon events arrive on the main run loop.
                let key = Unmanaged<CarbonEscapeHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { key.onPress?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKey)
    }

    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        onPress = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
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
