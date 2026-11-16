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
    /// With a match, the snapshot is what `confirmErased` needs.
    public func checkBeforeCaret(
        expected: String, _ completion: @escaping @Sendable (CaretCheck.Verdict, Erasure.Snapshot?) -> Void
    ) {
        thread.perform {
            let (verdict, snapshot) = Self.checkBeforeCaret(expected: expected)
            completion(verdict, snapshot)
        }
    }

    /// Posts the Backspaces of `retype`, waits until the field shows exactly
    /// the word gone (`Erasure.confirm`), and answers with the outcome and the
    /// number of Backspaces posted. Posts no keys of the new text: the caller
    /// types them on `.erased`, and only then. Answers before `deadline` (the
    /// fence's, on the `now` clock): with too little time left it posts nothing.
    public func eraseAndConfirm(
        _ retype: Retype, snapshot: Erasure.Snapshot, deadline: Double,
        _ completion: @escaping @Sendable (Erasure.Outcome, _ backspaces: Int) -> Void
    ) {
        thread.perform {
            // Read before anything is posted: with no field to read, nothing is erased.
            guard let element = Self.focusedElement() else { return completion(.stopped(.unreadable), 0) }
            guard Erasure.hasTime(at: Self.now, deadline: deadline) else { return completion(.stopped(.late), 0) }
            TextSink.post(retype, part: .erase)
            completion(Erasure.confirm(
                snapshot, deadline: deadline,
                now: { Self.now },
                pause: { usleep(2000) },
                read: { Self.reading(of: element, snapshot: snapshot) },
                restore: { TextSink.type($0, seq: retype.seq) }
            ), retype.deleteCount)
        }
    }

    /// The clock of `InputEngine` and the fence's deadline.
    public static var now: Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
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

    static func focusedElement() -> AXUIElement? {
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

    /// The field for `Erasure.judge`; nil when AX does not answer.
    static func reading(of element: AXUIElement, snapshot: Erasure.Snapshot) -> Erasure.Reading? {
        guard let selection = selectedRange(of: element) else { return nil }
        // The text before the word, up to the caret if it went back past the start.
        var lead = ""
        let leadStart = snapshot.start - snapshot.lead.utf16.count
        let leadEnd = min(snapshot.start, selection.location)
        if leadEnd > leadStart {
            guard let text = string(of: element, in: CFRange(location: leadStart, length: leadEnd - leadStart))
            else { return nil }
            lead = text
        }
        var remaining = ""
        // A caret far from the word is no word's remainder: judged by its length alone.
        let gap = selection.location - snapshot.start
        if gap > 0, gap <= snapshot.word.utf16.count {
            guard let text = string(of: element, in: CFRange(location: snapshot.start, length: gap)) else { return nil }
            remaining = text
        }
        return Erasure.Reading(location: selection.location, selectionLength: selection.length,
                               lead: lead, remaining: remaining)
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
            == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &selection),
              selection.location != kCFNotFound, selection.location >= 0
        else { return nil }
        return selection
    }

    /// Whether AX normally answers for this element: it has a role and a text
    /// value. Then a failed read is a failure, not a field that has no AX text.
    private static func answersText(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            && AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
            && value is String
    }

    private static func checkBeforeCaret(expected: String) -> (CaretCheck.Verdict, Erasure.Snapshot?) {
        guard let element = focusedElement() else { return (.unavailable, nil) }
        // Asked only when a read failed: `answersText` copies the whole text value.
        func unreadable() -> (CaretCheck.Verdict, Erasure.Snapshot?) {
            (answersText(element) ? .unreadable : .unavailable, nil)
        }
        // Chromium and Electron update their AX text after the keystroke has
        // already been typed, so a correct word can read as a mismatch there;
        // Telegram Desktop always reads as one. A false cancel breaks the
        // shortcut; skip the check in those apps.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, LaggingAXApps.contains(pid: pid) {
            return (.unavailable, nil)
        }
        guard let selection = selectedRange(of: element) else { return unreadable() }

        let length = expected.utf16.count
        // A selection would go with the first Backspace; the caret too close
        // to the start cannot have the word before it.
        guard selection.length == 0, selection.location >= length else { return (.mismatch, nil) }
        // One unit after the caret too, for an auto-closed bracket. At the end
        // of the text that range is too long; then without it.
        let start = selection.location - length
        let around = string(of: element, in: CFRange(location: start, length: length + 1))
            ?? string(of: element, in: CFRange(location: start, length: length))
        guard let around else { return unreadable() }
        let (verdict, actual) = CaretCheck.inspect(expected: expected, around: around)
        guard verdict == .match || verdict == .matchRaised, let actual else { return (verdict, nil) }
        // What is before the word, to see after the Backspaces that it is untouched.
        let leadStart = max(0, start - Erasure.Snapshot.leadLength)
        var lead = ""
        if start > leadStart {
            guard let text = string(of: element, in: CFRange(location: leadStart, length: start - leadStart))
            else { return unreadable() }
            lead = text
        }
        return (verdict, Erasure.Snapshot(start: start, lead: lead, word: actual))
    }

    /// `kAXStringForRangeParameterizedAttribute`, so a long document is not
    /// copied whole; `kAXValueAttribute` where the app lacks it.
    static func string(of element: AXUIElement, in range: CFRange) -> String? {
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
        /// The word is there, but the app raised its first letter (macOS
        /// autocapitalization). The retype goes ahead and brings the word back
        /// raised too (`Retype.raisingFirstLetter`).
        case matchRaised
        case mismatch
        /// AX does not tell anything about this field: no permission, no
        /// focused element, an app known to lag, or an element with no text
        /// value. The retype goes ahead, as it would without the check:
        /// refusing would make retyping useless in every app without AX text
        /// (terminals, games, many Electron apps), and the shortcut is the
        /// user's explicit request. Nothing can be read afterwards either, so
        /// the Backspaces and the text are posted together, as before.
        case unavailable
        /// The field has a role and a text value, so AX answers here, but this
        /// time the caret or the text could not be read. The retype is
        /// refused: it would erase a word nobody has seen.
        case unreadable
    }

    private static let closing: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`", "«": "»", "„": "“", "“": "”",
    ]

    /// `around`: the `expected.utf16.count` units before the caret, then the
    /// unit after it if there is one.
    public static func verdict(expected: String, around: String) -> Verdict {
        inspect(expected: expected, around: around).verdict
    }

    /// The verdict, and the word as the app has it (raised or not) when it is there.
    public static func inspect(expected: String, around: String) -> (verdict: Verdict, actual: String?) {
        let units = Array(around.utf16)
        let length = expected.utf16.count
        guard units.count >= length else { return (.mismatch, nil) }
        let before = String(decoding: units[..<length], as: UTF16.self)
        guard let match = CaretText.match(expected: expected, actual: before) else { return (.mismatch, nil) }
        // The word ends in an opening bracket the app closed: one Backspace
        // erases the pair in some editors, only the opening one in others.
        if units.count > length, let last = expected.last, let closer = closing[last],
           String(decoding: units[length...], as: UTF16.self).first == closer
        {
            return (.mismatch, nil)
        }
        return (match == .exact ? .match : .matchRaised, before)
    }
}

/// What a retype does with the verdict of its caret check.
public enum RetypeGate {
    public enum Decision: Equatable, Sendable {
        /// Post the retype. `verify`: post its Backspaces first and the keys
        /// only once the field shows the word gone (`Erasure`).
        case go(Retype, verify: Bool)
        /// Post nothing and send `.retypeCancelled`.
        case cancel(reason: String)
    }

    /// - Parameters:
    ///   - verdict: nil when no check ran: nothing to compare, or no probe.
    ///   - hasSnapshot: the check came back with what `Erasure` needs.
    public static func decide(_ retype: Retype, verdict: CaretCheck.Verdict?, hasSnapshot: Bool) -> Decision {
        switch verdict {
        case .mismatch:
            return .cancel(reason: "the text before the caret differs")
        case .unreadable:
            return .cancel(reason: "the field could not be read")
        case .matchRaised:
            // The app raised the first letter of the word: bring it back raised.
            return .go(retype.raisingFirstLetter(), verify: hasSnapshot && canVerify(retype))
        case .match:
            return .go(retype, verify: hasSnapshot && canVerify(retype))
        case .unavailable, nil:
            return .go(retype, verify: false)
        }
    }

    /// A retype of a selection erases nothing, one through AX posts no keys,
    /// and one with no keys has nothing to hold back.
    private static func canVerify(_ retype: Retype) -> Bool {
        retype.deleteCount > 0 && !retype.keys.isEmpty && !retype.viaAccessibility
    }
}

/// Apps whose AX text does not match what was typed: Chromium-based browsers
/// and Electron apps, found by the framework inside the app bundle, and the
/// apps in `bundleIDs`. Cached per process, because the check runs before
/// every retype.
enum LaggingAXApps {
    private static let cache = OSAllocatedUnfairLock<[pid_t: Bool]>(initialState: [:])

    private static let frameworks = [
        "Electron Framework.framework", "Chromium Embedded Framework.framework",
        "Google Chrome Framework.framework", "Microsoft Edge Framework.framework",
        "Brave Browser Framework.framework", "Arc Framework.framework", "Vivaldi Framework.framework",
        "Opera Framework.framework", "Chromium Framework.framework",
    ]

    /// Apps with Qt linked in statically, so no framework gives them away.
    /// Telegram Desktop (Telegram Lite in the App Store, and the build from
    /// telegram.org) answers every check with a mismatch: no retype there
    /// ever went through.
    private static let bundleIDs: Set<String> = ["org.telegram.desktop", "com.tdesktop.Telegram"]

    static func contains(pid: pid_t) -> Bool {
        if let known = cache.withLock({ $0[pid] }) { return known }
        let lagging = isLagging(bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL)
        cache.withLock { $0[pid] = lagging }
        return lagging
    }

    static func isLagging(bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        if let bundleID = Bundle(url: bundleURL)?.bundleIdentifier, isLagging(bundleID: bundleID) { return true }
        let frameworksURL = bundleURL.appending(path: "Contents/Frameworks", directoryHint: .isDirectory)
        return frameworks.contains { name in
            FileManager.default.fileExists(atPath: frameworksURL.appending(path: name).path)
        }
    }

    static func isLagging(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }
}
