// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Foundation
import os
import PerekeyCore

/// Reads and replaces text of the focused element through the accessibility
/// API: the selection to convert, and the text before the caret to check
/// before a retype's Backspaces.
///
/// Every call runs on a thread of its own, like `FocusObserver`'s and for the
/// same reason: an AX call to a hung app waits for the messaging timeout, and
/// neither the tap thread nor the main thread may wait. Completions are called
/// on that thread. Without the Accessibility permission nothing is asked, and
/// every answer is "unavailable".
public final class TextProbe: Sendable {
    /// Seconds an AX call to the focused element may wait. The pre-Backspace
    /// check holds the user's input meanwhile, so it is the low end of the
    /// 0.1–0.25 s docs/PLAN.md allows.
    public static let messagingTimeout: Float = 0.1

    public enum Selection: Hashable, Sendable {
        /// AX answered; empty if nothing is selected.
        case text(String)
        /// No permission, no focused element, the app does not answer or does
        /// not expose the selected text.
        case unavailable
    }

    private let thread = RunLoopThread(name: "Perekey AX text", qualityOfService: .userInteractive)

    public init() {}

    deinit {
        thread.stop()
    }

    /// The selected text of the focused element.
    public func selectedText(_ completion: @escaping @Sendable (Selection) -> Void) {
        thread.perform {
            guard let element = Self.focusedElement() else { return completion(.unavailable) }
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
            guard status == .success, let text = value as? String else { return completion(.unavailable) }
            completion(.text(text))
        }
    }

    /// Compares the text right before the caret with `expected`; see `CaretCheck`.
    public func checkBeforeCaret(expected: String, _ completion: @escaping @Sendable (CaretCheck.Verdict) -> Void) {
        thread.perform {
            completion(Self.checkBeforeCaret(expected: expected))
        }
    }

    /// Replaces the selection of the focused element with `text`. Breaks ⌘Z and
    /// formatting in many apps: only for apps where the user turned it on.
    public func replaceSelection(with text: String, _ completion: @escaping @Sendable (Bool) -> Void) {
        thread.perform {
            guard let element = Self.focusedElement() else { return completion(false) }
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            completion(status == .success)
        }
    }

    // MARK: - AX thread

    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element this sets the default for the whole
        // process; keep FocusObserver's value there.
        AXUIElementSetMessagingTimeout(systemWide, FocusObserver.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func checkBeforeCaret(expected: String) -> CaretCheck.Verdict {
        guard let element = focusedElement() else { return .unavailable }
        // Chromium and Electron update their AX text after the keystroke has
        // already been typed, so a correct word can read as a mismatch there.
        // A false cancel breaks the shortcut; skip the check in those apps.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, LaggingAXApps.contains(pid: pid) {
            return .unavailable
        }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
            == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return .unavailable }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &selection),
              selection.location != kCFNotFound, selection.location >= 0
        else { return .unavailable }

        let length = expected.utf16.count
        // A selection would go with the first Backspace; the caret too close
        // to the start cannot have the word before it.
        guard selection.length == 0, selection.location >= length else { return .mismatch }
        // One unit after the caret too, for an auto-closed bracket. At the end
        // of the text that range is too long; then without it.
        let start = selection.location - length
        let around = string(of: element, in: CFRange(location: start, length: length + 1))
            ?? string(of: element, in: CFRange(location: start, length: length))
        guard let around else { return .unavailable }
        return CaretCheck.verdict(expected: expected, around: around)
    }

    /// `kAXStringForRangeParameterizedAttribute`, so a long document is not
    /// copied whole; `kAXValueAttribute` where the app lacks it.
    private static func string(of element: AXUIElement, in range: CFRange) -> String? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        )
        if status == .success, let text = value as? String { return text }
        guard status == .parameterizedAttributeUnsupported || status == .attributeUnsupported else { return nil }
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let whole = value as? NSString, range.location + range.length <= whole.length
        else { return nil }
        return whole.substring(with: NSRange(location: range.location, length: range.length))
    }
}

/// Whether the text before the caret is what the retype is about to erase.
///
/// The word buffer knows which keys were typed, not what the app made of them.
/// Autocomplete in an address bar, autocorrect and text replacements on Space,
/// auto-closed brackets and quotes (х ъ ж э б ю in the English layout are
/// `[ ] ; ' , .`), macOS predictive text: each changes the text, and the
/// Backspaces would then erase something else.
public enum CaretCheck {
    public enum Verdict: Hashable, Sendable {
        case match
        case mismatch
        /// AX cannot tell: no permission, no answer within the timeout, or the
        /// app exposes no text. The retype goes ahead, as it would without the
        /// check: refusing would make retyping useless in every app without
        /// AX text (terminals, games, many Electron apps), and the shortcut is
        /// the user's explicit request.
        case unavailable
    }

    private static let closing: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "«": "»", "„": "“", "“": "”",
    ]

    /// `around`: the `expected.utf16.count` units before the caret, then the
    /// unit after it if there is one.
    public static func verdict(expected: String, around: String) -> Verdict {
        let units = Array(around.utf16)
        let length = expected.utf16.count
        guard units.count >= length else { return .mismatch }
        let before = String(decoding: units[..<length], as: UTF16.self)
        guard normalized(before) == normalized(expected) else { return .mismatch }
        // The word ends in an opening bracket the app closed: one Backspace
        // erases the pair in some editors, only the opening one in others.
        if units.count > length, let last = expected.last, let closer = closing[last],
           String(decoding: units[length...], as: UTF16.self).first == closer
        {
            return .mismatch
        }
        return .match
    }

    /// Browsers turn a trailing space of contenteditable text into a no-break space.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

/// Apps whose AX text lags behind typing: Chromium-based browsers and
/// Electron apps, found by the framework inside the app bundle. Cached per
/// process, because the check runs before every retype.
enum LaggingAXApps {
    private static let cache = OSAllocatedUnfairLock<[pid_t: Bool]>(initialState: [:])

    private static let frameworks = [
        "Electron Framework.framework", "Chromium Embedded Framework.framework",
        "Google Chrome Framework.framework", "Microsoft Edge Framework.framework",
        "Brave Browser Framework.framework", "Arc Framework.framework", "Vivaldi Framework.framework",
        "Opera Framework.framework", "Chromium Framework.framework",
    ]

    static func contains(pid: pid_t) -> Bool {
        if let known = cache.withLock({ $0[pid] }) { return known }
        let lagging = isLagging(bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL)
        cache.withLock { $0[pid] = lagging }
        return lagging
    }

    static func isLagging(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let frameworksURL = bundleURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        return frameworks.contains { name in
            FileManager.default.fileExists(atPath: frameworksURL.appending(path: name).path)
        }
    }
}
