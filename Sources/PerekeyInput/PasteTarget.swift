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
        /// For an element inside an `AXWebArea`: the `AXURL` of the topmost
        /// web area (the page, not an editor's iframe), or the window's
        /// `AXDocument`. Nil outside web content, without either, or for an
        /// address that names no page (`about:`, `data:`, empty).
        public var webDocument: String?
        /// `AXPosition` and `AXSize`, in AX screen coordinates.
        public var frame: CGRect?

        public init(ref: AXElementRef, role: String?, subrole: String?, identifier: String?,
                    webDocument: String? = nil, frame: CGRect? = nil)
        {
            self.ref = ref
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.webDocument = webDocument
            self.frame = frame
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

    /// The target of an app that gave no AX answer: the PID alone, from the
    /// frontmost app. `isSame(as:)` then compares the process only.
    public static func app(pid: pid_t) -> PasteTarget {
        PasteTarget(pid: pid, window: nil, element: nil)
    }

    /// Whether `current` is still this target: same process, same window, and
    /// the same element as far as it can be told.
    ///
    /// The window is compared whenever this target has one: a window the app
    /// no longer reports is a change. The element must be the same AX object
    /// (`CFEqual`): tabs of Terminal are text areas without identifiers in one
    /// window, and only the reference tells them apart. One exception: web
    /// content (Chromium, Electron) hands out a new AX object for the same
    /// field after a re-render. Inside an `AXWebArea` a new reference is the
    /// same target if
    /// - the page is the same (`webDocument`: another tab with another page
    ///   is a change; titles are not compared);
    /// - role, subrole and identifier match, an identifier on one side only
    ///   included;
    /// - and the field is the same one on the page: the same non-empty
    ///   identifier, or the same frame within `frameTolerance`. The editor
    ///   and the terminal of VS Code are text areas without identifiers on
    ///   one page; only their place tells them apart.
    /// Two tabs of one window showing the same address still look alike when
    /// the field has an identifier or sits at the same place.
    ///
    /// An element the target had and the app no longer reports is a change;
    /// a target without an element compares no element.
    public func isSame(as current: PasteTarget) -> Bool {
        guard pid == current.pid else { return false }
        if let window, window != current.window { return false }
        return Self.sameElement(element, current.element)
    }

    /// Points a rebuilt web field may move, e.g. after a scroll by a pixel.
    public static let frameTolerance: CGFloat = 2

    static func sameElement(_ old: Element?, _ new: Element?) -> Bool {
        guard let old else { return true }
        guard let new else { return false }
        if old.ref == new.ref { return true }
        guard let document = old.webDocument, document == new.webDocument else { return false }
        guard old.role == new.role, old.subrole == new.subrole, old.identifier == new.identifier else { return false }
        if old.identifier != nil { return true }
        guard let oldFrame = old.frame, let newFrame = new.frame else { return false }
        return abs(oldFrame.minX - newFrame.minX) <= frameTolerance
            && abs(oldFrame.minY - newFrame.minY) <= frameTolerance
            && abs(oldFrame.width - newFrame.width) <= frameTolerance
            && abs(oldFrame.height - newFrame.height) <= frameTolerance
    }

    /// Whether `address` names a page that two reads can be compared by.
    /// `about:blank` is every new iframe (TinyMCE, CKEditor) and `data:` any
    /// generated one.
    static func isPageAddress(_ address: String?) -> Bool {
        guard let address, !address.isEmpty else { return false }
        let lower = address.lowercased()
        return !lower.hasPrefix("about:") && !lower.hasPrefix("data:")
    }
}

/// What became of an AX action on another app.
public enum AXActionOutcome: Sendable, Equatable {
    case done
    /// Certainly not done: nothing to act on, or the app refused.
    case notDone
    /// The app did not answer in time. The action may still happen.
    case unknown
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
    /// an answer within `timeout`. `frontmostPID` (from `NSWorkspace`, read on
    /// main) is asked when the system-wide element does not answer, which
    /// happens to processes outside the GUI session.
    public func current(frontmostPID: pid_t? = nil) async -> PasteTarget? {
        await run { Self.read(frontmostPID: frontmostPID) }
    }

    /// Replaces the selection of `element` with `text` through AX, without
    /// the pasteboard. For apps where ⌘V does not arrive.
    public func setSelectedText(_ text: String, in element: AXElementRef) async -> AXActionOutcome {
        await run { timedOut in
            guard !timedOut() else { return .notDone }
            return Self.outcome(AXUIElementSetAttributeValue(element.element, kAXSelectedTextAttribute as CFString,
                                                             text as CFString))
        } ?? .unknown
    }

    /// Up to `count` characters before the caret of `element`: "" at the start of
    /// the text, nil when the field does not tell (no range, no text, no answer
    /// in time). A selection counts from its start. Text rules read it to fit
    /// case and space to what is already there.
    public func textBeforeCaret(in element: AXElementRef, count: Int = 8) async -> String? {
        await run { timedOut in
            let element = element.element
            AXUIElementSetMessagingTimeout(element, FocusObserver.messagingTimeout)
            var rangeValue: CFTypeRef?
            guard !timedOut(),
                  AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
                  let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
            else { return nil }
            var selection = CFRange()
            guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &selection),
                  selection.location != kCFNotFound, selection.location >= 0
            else { return nil }
            if selection.location == 0 { return "" }
            let start = max(0, selection.location - count)
            return TextProbe.string(of: element, in: CFRange(location: start, length: selection.location - start))
        }
    }

    /// Presses the menu item of app `pid` that has ⌘V as its shortcut (Edit ▸
    /// Paste in any language).
    public func pressPasteMenuItem(pid: pid_t) async -> AXActionOutcome {
        await run { timedOut in Self.pressPasteMenuItem(pid: pid, timedOut: timedOut) } ?? .unknown
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        await run { _ in work() }
    }

    /// Runs `work` on the AX thread; nil after `timeout`. `work` gets a check
    /// that tells whether the caller has given up on it already: an action
    /// must not start after its caller was told "unknown" and moved on.
    private func run<T: Sendable>(_ work: @escaping @Sendable (_ timedOut: @Sendable () -> Bool) -> T?) async -> T? {
        let once = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        return await withCheckedContinuation { continuation in
            once.withLock { $0 = continuation }
            @Sendable func finish(_ value: T?) {
                once.withLock { pending -> CheckedContinuation<T?, Never>? in
                    defer { pending = nil }
                    return pending
                }?.resume(returning: value)
            }
            @Sendable func timedOut() -> Bool { once.withLock { $0 == nil } }
            thread.perform { finish(work(timedOut)) }
            let deadline = DispatchTime.now() + .milliseconds(Self.timeoutMilliseconds)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) { finish(nil) }
        }
    }

    /// `cannotComplete` is AX's word for "the app did not answer": the
    /// message may still arrive.
    private static func outcome(_ error: AXError) -> AXActionOutcome {
        switch error {
        case .success: .done
        case .cannotComplete: .unknown
        default: .notDone
        }
    }

    // MARK: - AX thread

    private struct Focus {
        var pid: pid_t
        var app: AXUIElement
        var element: AXUIElement?
    }

    private static func focused(frontmostPID: pid_t?) -> Focus? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the default for the whole
        // process; keep FocusObserver's value there.
        AXUIElementSetMessagingTimeout(systemWide, FocusObserver.messagingTimeout)
        var pid: pid_t = 0
        let app: AXUIElement
        if let focusedApp = element(systemWide, kAXFocusedApplicationAttribute),
           AXUIElementGetPid(focusedApp, &pid) == .success, pid > 0
        {
            app = focusedApp
        } else if let frontmostPID, frontmostPID > 0 {
            pid = frontmostPID
            app = AXUIElementCreateApplication(frontmostPID)
        } else {
            return nil
        }
        AXUIElementSetMessagingTimeout(app, FocusObserver.messagingTimeout)
        return Focus(pid: pid, app: app, element: element(app, kAXFocusedUIElementAttribute))
    }

    private static func read(frontmostPID: pid_t?) -> PasteTarget? {
        guard let focus = focused(frontmostPID: frontmostPID) else { return nil }
        let window = focus.element.flatMap { element($0, kAXWindowAttribute) }
            ?? element(focus.app, kAXFocusedWindowAttribute)
        let described = focus.element.map { element in
            PasteTarget.Element(
                ref: AXElementRef(element),
                role: string(element, kAXRoleAttribute),
                subrole: string(element, kAXSubroleAttribute),
                identifier: string(element, kAXIdentifierAttribute).nonEmpty
                    ?? string(element, "AXDOMIdentifier").nonEmpty,
                webDocument: webDocument(of: element, window: window),
                frame: frame(of: element)
            )
        }
        return PasteTarget(pid: focus.pid, window: window.map(AXElementRef.init), element: described)
    }

    /// Deepest a focused field sits below its web area; Electron apps nest deep.
    private static let maxWebAreaDepth = 64

    /// The document of the topmost `AXWebArea` above `element`, see
    /// `PasteTarget.Element.webDocument`.
    private static func webDocument(of element: AXUIElement, window: AXUIElement?) -> String? {
        var current: AXUIElement? = element
        var topmost: AXUIElement?
        for _ in 0..<maxWebAreaDepth {
            guard let node = current else { break }
            if string(node, kAXRoleAttribute) == "AXWebArea" { topmost = node }
            current = Self.element(node, kAXParentAttribute)
        }
        guard let topmost else { return nil }
        let address = url(topmost, kAXURLAttribute) ?? window.flatMap { url($0, kAXDocumentAttribute) }
        return PasteTarget.isPageAddress(address) ? address : nil
    }

    private static func url(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value
        else { return nil }
        if let url = value as? URL { return url.absoluteString.nonEmpty }
        return (value as? String).nonEmpty
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID(),
              let size, CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// The press of the target app's own Paste item, not of whatever app has
    /// the focus by now. Not started once the caller gave up (`timedOut`).
    private static func pressPasteMenuItem(pid: pid_t, timedOut: () -> Bool) -> AXActionOutcome {
        guard AXIsProcessTrusted() else { return .notDone }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusObserver.messagingTimeout)
        guard let bar = element(app, kAXMenuBarAttribute) else { return .notDone }
        for menu in children(bar) {
            for submenu in children(menu) {
                for item in children(submenu) where isPaste(item) {
                    guard !timedOut() else { return .notDone }
                    return outcome(AXUIElementPerformAction(item, kAXPressAction as CFString))
                }
            }
        }
        return .notDone
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
