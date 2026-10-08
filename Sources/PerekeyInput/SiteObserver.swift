// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import os
import PerekeyCore

/// Reports the host of the page in the frontmost browser window.
///
/// Supported: Safari, Chrome, Arc, Brave, Edge, Vivaldi (`browserBundleIDs`).
/// The URL comes from `AXURL` of the window's `AXWebArea`; where a browser does
/// not expose it, the address field's value is the fallback.
///
/// Like `FocusObserver`, every AX call runs on a thread of its own with the
/// short messaging timeout, and nothing polls: reads are triggered by app
/// activation, by the focused window changing and by the window's title
/// changing (a tab switch or a navigation changes the title). Without the
/// Accessibility permission nothing is asked and no host is reported.
///
/// `onHost` is called on the AX thread with the normalized host, or `nil` when
/// the frontmost app is not a supported browser or its URL is unknown. Only
/// changes are reported. The URL itself never leaves this file and is never logged.
///
/// Not exercised in CI or in the snapshot shell, which have no AX permission:
/// the tree walk and the notifications need a real browser and a grant.
public final class SiteObserver: Sendable {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta",
        "com.vivaldi.Vivaldi",
    ]

    private struct Running: Sendable {
        let thread: RunLoopThread
        let worker: Worker
        let notifications: NotificationTokens
    }

    private let onHost: @Sendable (String?) -> Void
    private let running = OSAllocatedUnfairLock<Running?>(initialState: nil)

    public init(onHost: @escaping @Sendable (String?) -> Void) {
        self.onHost = onHost
    }

    deinit {
        stop()
    }

    @MainActor
    public func start() {
        guard running.withLock({ $0 == nil }) else { return }
        let worker = Worker(publish: onHost)
        let thread = RunLoopThread(name: "Perekey AX sites", qualityOfService: .utility)
        let notifications = NotificationTokens()
        notifications.observe(NSWorkspace.shared.notificationCenter, [NSWorkspace.didActivateApplicationNotification]) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let target = Worker.App(app)
            thread.perform { worker.activate(target) }
        }
        running.withLock { $0 = Running(thread: thread, worker: worker, notifications: notifications) }
        let target = Worker.App(NSWorkspace.shared.frontmostApplication)
        thread.perform { worker.activate(target) }
    }

    /// Reads again, e.g. after the user grants Accessibility.
    @MainActor
    public func refresh() {
        guard let current = running.withLock({ $0 }) else { return }
        let target = Worker.App(NSWorkspace.shared.frontmostApplication)
        current.thread.perform { current.worker.activate(target) }
    }

    public func stop() {
        guard let current = running.withLock({ state -> Running? in
            defer { state = nil }
            return state
        }) else { return }
        current.thread.stop { current.worker.detach() }
    }

    /// The host in one AX value a browser exposes: a `URL` attribute, or the
    /// address field's text (often without a scheme).
    static func host(fromAXValue value: CFTypeRef?) -> String? {
        if let url = value as? URL { return SiteHost.normalized(url.absoluteString) }
        guard let text = value as? String else { return nil }
        return SiteHost.normalized(text)
    }
}

/// The AX side. Confined to the AX thread, hence `@unchecked`.
private final class Worker: @unchecked Sendable {
    struct App: Sendable, Equatable {
        var pid: pid_t
        var bundleID: String

        init?(_ app: NSRunningApplication?) {
            guard let app, app.processIdentifier > 0, let id = app.bundleIdentifier else { return nil }
            pid = app.processIdentifier
            bundleID = id
        }
    }

    /// Most elements one read visits. A browser window is shallow around the
    /// web area; the cap keeps a pathological tree from costing seconds.
    private static let visitLimit = 80
    private static let depthLimit = 8

    private let publish: @Sendable (String?) -> Void
    private var app: App?
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var watchedWindow: AXUIElement?
    private var lastHost: String??

    init(publish: @escaping @Sendable (String?) -> Void) {
        self.publish = publish
    }

    func activate(_ target: App?) {
        let switched = target != app
        app = target
        guard let target, SiteObserver.browserBundleIDs.contains(target.bundleID), AXIsProcessTrusted() else {
            detach()
            send(nil)
            return
        }
        if switched || observer == nil {
            detach()
            attach(to: target.pid)
        }
        read()
    }

    func detach() {
        if let observer {
            if let watchedWindow {
                AXObserverRemoveNotification(observer, watchedWindow, kAXTitleChangedNotification as CFString)
            }
            if let appElement {
                AXObserverRemoveNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        appElement = nil
        watchedWindow = nil
    }

    private func attach(to pid: pid_t) {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, FocusObserver.messagingTimeout)
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Worker>.fromOpaque(refcon).takeUnretainedValue().changed()
        }, &created)
        guard status == .success, let created else { return }
        // Unretained: `detach` removes the source before the worker can go away,
        // and both run on this thread.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, element, kAXFocusedWindowChangedNotification as CFString, refcon)
            == .success
        else { return }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        appElement = element
    }

    private func changed() {
        guard app != nil else { return }
        read()
    }

    private func read() {
        guard let appElement else { return send(nil) }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        if status == .apiDisabled {
            detach()
            return send(nil)
        }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return send(nil) }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, FocusObserver.messagingTimeout)
        watchTitle(of: window)
        send(host(in: window))
    }

    /// A tab switch or a navigation changes the window title.
    private func watchTitle(of window: AXUIElement) {
        guard let observer else { return }
        if let watchedWindow, CFEqual(watchedWindow, window) { return }
        if let watchedWindow {
            AXObserverRemoveNotification(observer, watchedWindow, kAXTitleChangedNotification as CFString)
        }
        watchedWindow = nil
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon) == .success {
            watchedWindow = window
        }
    }

    /// Breadth-first through the window for the `AXWebArea`; its `AXURL` wins.
    /// The address field's value is the fallback.
    private func host(in window: AXUIElement) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var addressField: String?
        while index < queue.count, index < Self.visitLimit {
            let (element, depth) = queue[index]
            index += 1
            AXUIElementSetMessagingTimeout(element, FocusObserver.messagingTimeout)
            switch string(element, kAXRoleAttribute) {
            case "AXWebArea":
                var url: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &url) == .success,
                   let host = SiteObserver.host(fromAXValue: url)
                {
                    return host
                }
                continue // The page's own tree is not the toolbar.
            case kAXTextFieldRole, kAXComboBoxRole:
                if addressField == nil, let text = string(element, kAXValueAttribute), !text.contains(" ") {
                    addressField = SiteHost.normalized(text)
                }
            default:
                break
            }
            guard depth < Self.depthLimit else { continue }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement]
            else { continue }
            queue.append(contentsOf: list.map { ($0, depth + 1) })
        }
        return addressField
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func send(_ host: String?) {
        if let lastHost, lastHost == host { return }
        lastHost = .some(host)
        publish(host)
    }
}
