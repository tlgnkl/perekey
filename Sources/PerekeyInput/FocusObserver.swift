// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import os
import PerekeyCore

/// Follows the frontmost app and its focused element, and tells whether that
/// element is a password field.
///
/// All accessibility calls run on a thread of their own with its own run loop,
/// which also carries the `AXObserver` source: never on the main thread, never
/// on the tap thread. An AX call to a hung app waits for the messaging timeout,
/// so every element gets `messagingTimeout` instead of the default seconds.
/// `onFocus` is called on that thread; the receiver hands the value to the tap
/// thread (`CFRunLoopPerformBlock`) and may call `SecureInputMonitor.refresh()`
/// on main, since a newly focused password field often turns Secure Input on.
///
/// Right after an app switch the focused element is not known yet, and the
/// observer publishes `Focus.unknown`; the core must not switch automatically
/// then. Without the Accessibility permission the observer makes no AX calls
/// and every focus stays unknown. It checks the permission again on each app
/// activation and on `refresh()`, not on a timer: idle CPU stays at 0.
///
/// Password fields are found by subrole (`AXSecureTextField`), not by role:
/// their role is the plain `AXTextField`.
public final class FocusObserver: Sendable {
    /// Seconds an AX call may wait for an app. docs/PLAN.md asks for 0.1–0.25 s.
    public static let messagingTimeout: Float = 0.2

    private struct Running: Sendable {
        let thread: RunLoopThread
        let worker: Worker
        let notifications: NotificationTokens
    }

    private let onFocus: @Sendable (Focus) -> Void
    private let running = OSAllocatedUnfairLock<Running?>(initialState: nil)

    /// `onFocus` is called on the AX thread.
    public init(onFocus: @escaping @Sendable (Focus) -> Void) {
        self.onFocus = onFocus
    }

    deinit {
        stop()
    }

    /// Starts following the frontmost app; publishes its focus right away,
    /// unknown at first. Does nothing if already started.
    @MainActor
    public func start() {
        guard running.withLock({ $0 == nil }) else { return }
        let worker = Worker(publish: onFocus)
        let thread = RunLoopThread(name: "Perekey AX", qualityOfService: .userInitiated)
        let notifications = NotificationTokens()
        let center = NSWorkspace.shared.notificationCenter
        notifications.observe(center, [NSWorkspace.didActivateApplicationNotification]) { note in
            // Posted on main; only the Sendable PID and bundle ID go to the AX thread.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let target = Worker.App(app)
            thread.perform { worker.activate(target) }
        }
        running.withLock { $0 = Running(thread: thread, worker: worker, notifications: notifications) }
        let target = Worker.App(NSWorkspace.shared.frontmostApplication)
        thread.perform { worker.activate(target) }
    }

    /// Reads the frontmost app's focus again, and the permission with it: call
    /// after the user grants Accessibility. Publishes only a changed focus.
    @MainActor
    public func refresh() {
        guard let current = running.withLock({ $0 }) else { return }
        let target = Worker.App(NSWorkspace.shared.frontmostApplication)
        current.thread.perform { current.worker.activate(target) }
    }

    /// Stops following and ends the thread. Does not wait for it.
    public func stop() {
        guard let current = running.withLock({ state -> Running? in
            defer { state = nil }
            return state
        }) else { return }
        current.thread.stop { current.worker.detach() }
    }

    /// The AX thread while started. For tests.
    var thread: RunLoopThread? { running.withLock { $0?.thread } }

    /// What an element's subrole says about focus. A failed read other than
    /// "no such attribute" leaves the focus unknown: a hung app says nothing.
    static func focus(bundleID: String?, subroleError: AXError, subrole: String?) -> Focus {
        switch subroleError {
        case .success:
            Focus(bundleID: bundleID, isSecureField: subrole == kAXSecureTextFieldSubrole)
        case .noValue, .attributeUnsupported:
            Focus(bundleID: bundleID)
        default:
            .unknown(bundleID: bundleID)
        }
    }
}

/// The AX side. Confined to the AX thread: only blocks run by `RunLoopThread`
/// and the observer callback on its run loop touch it, hence `@unchecked`.
private final class Worker: @unchecked Sendable {
    struct App: Sendable, Equatable {
        var pid: pid_t
        var bundleID: String?

        init?(_ app: NSRunningApplication?) {
            guard let app, app.processIdentifier > 0 else { return nil }
            pid = app.processIdentifier
            bundleID = app.bundleIdentifier
        }
    }

    private let publish: @Sendable (Focus) -> Void
    private var app: App?
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var lastPublished: Focus?
    /// Apps already asked for `AXManualAccessibility`, by PID.
    private var manualAccessibilityAsked: Set<pid_t> = []

    init(publish: @escaping @Sendable (Focus) -> Void) {
        self.publish = publish
    }

    /// The frontmost app is `target`: a switch, or a refresh of the same app.
    func activate(_ target: App?) {
        let switched = target != app
        app = target
        guard let target else {
            detach()
            send(.unknown(bundleID: nil), always: switched)
            return
        }
        // The permission can be granted or revoked at any time; `AXIsProcessTrusted`
        // is a cheap local check, unlike a timer it costs nothing while idle.
        guard AXIsProcessTrusted() else {
            detach()
            send(.unknown(bundleID: target.bundleID), always: switched)
            return
        }
        if switched || observer == nil {
            detach()
            // The new app's focused element is not known until AX answers.
            send(.unknown(bundleID: target.bundleID), always: switched)
            attach(to: target.pid)
        }
        readFocusedElement()
    }

    func detach() {
        if let observer {
            if let appElement {
                AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
    }

    private func attach(to pid: pid_t) {
        // Sets the default for every element of this process, including ones AX
        // hands back later; the app element gets it explicitly as well.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), FocusObserver.messagingTimeout)
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, FocusObserver.messagingTimeout)
        appElement = element
        askForManualAccessibility(element, pid: pid)

        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<Worker>.fromOpaque(refcon).takeUnretainedValue().focusChanged(to: element)
        }, &created)
        guard status == .success, let created else { return }
        // Unretained: `detach` removes the source before the worker can go away,
        // and both run on this thread.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Fails for apps without AX support or that do not answer in time; the
        // focus then stays unknown until the next activation or `refresh()`.
        guard AXObserverAddNotification(created, element, kAXFocusedUIElementChangedNotification as CFString,
                                        refcon) == .success
        else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    /// Chromium and Electron build their AX tree only for assistive apps they
    /// recognize, and `AXManualAccessibility` asks for it. Other apps answer
    /// "attribute unsupported", so it is set on every app once per PID instead
    /// of guessing which ones embed Chromium. The cost: the app keeps an AX tree,
    /// some memory and CPU on heavy pages. `AXEnhancedUserInterface`, the older
    /// switch, is not used: it also turns on VoiceOver-style behaviour, and window
    /// managers (Rectangle, Magnet) document that it breaks window animations and
    /// moves. Chromium password fields turn Secure Input on in any case, so AX is
    /// the second line of defence there.
    private func askForManualAccessibility(_ element: AXUIElement, pid: pid_t) {
        guard manualAccessibilityAsked.insert(pid).inserted else { return }
        if manualAccessibilityAsked.count > 512 { manualAccessibilityAsked = [pid] }
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func readFocusedElement() {
        guard let appElement else { return }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .apiDisabled {
            // Permission revoked since the check.
            detach()
            send(.unknown(bundleID: app?.bundleID), always: false)
            return
        }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        send(focus(of: unsafeDowncast(value, to: AXUIElement.self)), always: false)
    }

    private func focusChanged(to element: AXUIElement) {
        // Every notification counts, even with an equal `Focus`: another field
        // of the same kind is still a new place, and the core forgets the word.
        send(focus(of: element), always: true)
    }

    private func focus(of element: AXUIElement) -> Focus {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        return FocusObserver.focus(bundleID: app?.bundleID, subroleError: status, subrole: value as? String)
    }

    private func send(_ focus: Focus, always: Bool) {
        guard always || focus != lastPublished else { return }
        lastPublished = focus
        publish(focus)
    }
}
