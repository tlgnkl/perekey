// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import Foundation
import os

/// An AX element that can cross threads. AX elements are immutable references
/// to another process's object; equality is `CFEqual`, which compares the
/// process and the element token, not the pointer.
public struct AXElementRef: @unchecked Sendable, Equatable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

/// Where dictated text goes: the app, its window and the focused element as
/// they were when the user started speaking. Text is pasted only into the same
/// target (`isSame(as:)`).
public struct PasteTarget: Sendable, Equatable {
    /// The focused element, with what still identifies it after the app
    /// rebuilds its AX objects.
    public struct Element: Sendable, Equatable {
        public var ref: AXElementRef
        public var role: String?
        public var subrole: String?
        /// `AXIdentifier`, or Chromium's `AXDOMIdentifier` (the HTML `id`).
        public var identifier: String?

        public init(ref: AXElementRef, role: String?, subrole: String?, identifier: String?) {
            self.ref = ref
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
        }

        public var isSecureField: Bool { subrole == kAXSecureTextFieldSubrole }
    }

    public var pid: pid_t
    /// The focused element's window, or the app's focused window; nil if the
    /// app did not answer.
    public var window: AXElementRef?
    public var element: Element?

    public init(pid: pid_t, window: AXElementRef?, element: Element?) {
        self.pid = pid
        self.window = window
        self.element = element
    }

    /// The focus is a password field.
    public var isSecureField: Bool { element?.isSecureField ?? false }

    /// Whether `current` is still this target: same process, same window, and
    /// the same element as far as it can be told.
    ///
    /// The window is compared whenever this target has one: a window the app
    /// no longer reports is a change. The element is compared by `CFEqual`
    /// first, but Chromium and Electron hand out a new AX object for the same
    /// text field after a re-render (and xterm.js recreates its textarea), so
    /// a different reference alone is not a change. Then role, subrole and the
    /// identifier decide: focus that moved from the address bar to the page,
    /// or into a password field, changes the role or the subrole. Two plain
    /// fields without identifiers in one window are taken as the same target;
    /// the window check already ruled out another document. An element missing
    /// on either side (the app did not answer) is not compared.
    public func isSame(as current: PasteTarget) -> Bool {
        guard pid == current.pid else { return false }
        if let window, window != current.window { return false }
        return Self.sameElement(element, current.element)
    }

    static func sameElement(_ old: Element?, _ new: Element?) -> Bool {
        guard let old, let new else { return true }
        if old.ref == new.ref { return true }
        guard old.role == new.role, old.subrole == new.subrole else { return false }
        if let oldID = old.identifier, let newID = new.identifier { return oldID == newID }
        return true
    }
}

/// Reads the paste target on a thread of its own, like `CaretLocator`: an app
/// that hangs must not block the main thread. Every AX call waits at most
/// `FocusObserver.messagingTimeout`, and the whole read at most `timeout`.
public final class PasteTargetReader: Sendable {
    /// The longest a read may take, a stuck thread included.
    public static let timeout: Duration = .milliseconds(timeoutMilliseconds)
    private static let timeoutMilliseconds = 1000

    private let thread = RunLoopThread(name: "Perekey AX paste", qualityOfService: .userInitiated)

    public init() {}

    deinit {
        thread.stop()
    }

    /// The current target, or nil without the permission, a frontmost app, or
    /// an answer within `timeout`.
    public func current() async -> PasteTarget? {
        await run(Self.read)
    }

    /// Replaces the selection of the focused element with `text` through AX,
    /// without the pasteboard. For apps where ⌘V does not arrive.
    public func setSelectedText(_ text: String) async -> Bool {
        await run {
            guard let element = Self.focused()?.element else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString,
                                                text as CFString) == .success
        } ?? false
    }

    /// Presses the menu item of the frontmost app that has ⌘V as its shortcut
    /// (Edit ▸ Paste in any language). Does not wait for the press.
    public func pressPasteMenuItem() {
        thread.perform { _ = Self.pressPasteMenuItem() }
    }

    /// Runs `work` on the AX thread; nil after `timeout`.
    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        let once = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            once.withLock { $0 = continuation }
            @Sendable func finish(_ value: T?) {
                once.withLock { pending -> CheckedContinuation<T?, Never>? in
                    defer { pending = nil }
                    return pending
                }?.resume(returning: value)
            }
            thread.perform { finish(work()) }
            let deadline = DispatchTime.now() + .milliseconds(Self.timeoutMilliseconds)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { finish(nil) }
        }
    }

    // MARK: - AX thread

    private struct Focus {
        var pid: pid_t
        var app: AXUIElement
        var element: AXUIElement?
    }

    private static func focused() -> Focus? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the default for the whole
        // process; keep FocusObserver's value there.
        AXUIElementSetMessagingTimeout(systemWide, FocusObserver.messagingTimeout)
        guard let app = element(systemWide, kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success, pid > 0 else { return nil }
        AXUIElementSetMessagingTimeout(app, FocusObserver.messagingTimeout)
        return Focus(pid: pid, app: app, element: element(app, kAXFocusedUIElementAttribute))
    }

    private static func read() -> PasteTarget? {
        guard let focus = focused() else { return nil }
        let window = focus.element.flatMap { element($0, kAXWindowAttribute) }
            ?? element(focus.app, kAXFocusedWindowAttribute)
        let described = focus.element.map { element in
            PasteTarget.Element(
                ref: AXElementRef(element),
                role: string(element, kAXRoleAttribute),
                subrole: string(element, kAXSubroleAttribute),
                identifier: string(element, kAXIdentifierAttribute).nonEmpty
                    ?? string(element, "AXDOMIdentifier").nonEmpty
            )
        }
        return PasteTarget(pid: focus.pid, window: window.map(AXElementRef.init), element: described)
    }

    private static func pressPasteMenuItem() -> Bool {
        guard let focus = focused(), let bar = element(focus.app, kAXMenuBarAttribute) else { return false }
        for menu in children(bar) {
            for submenu in children(menu) {
                for item in children(submenu) where isPaste(item) {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// ⌘V exactly: `AXMenuItemCmdModifiers` 0 means ⌘ alone (Paste and Match
    /// Style is ⌥⇧⌘V).
    private static func isPaste(_ item: AXUIElement) -> Bool {
        guard string(item, kAXMenuItemCmdCharAttribute)?.uppercased() == "V" else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &value) == .success,
              let modifiers = value as? Int
        else { return false }
        return modifiers == 0
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject]
        else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? unsafeDowncast(item, to: AXUIElement.self) : nil
        }
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

private extension String? {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
