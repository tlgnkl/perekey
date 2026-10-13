// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics

/// What became of a paste.
public enum PasteResult: Equatable, Sendable {
    case pasted
    /// The user moved to another app, window or field: nothing was pasted and
    /// the pasteboard was not touched.
    case targetChanged
    /// The focus is a password field, or Secure Input is on: nothing was
    /// pasted, and the text must not go to the history either.
    case secureField
    case failed(PasteFailure)
}

public enum PasteFailure: Equatable, Sendable {
    case emptyText
    /// Without Accessibility no key or AX action reaches another app.
    case noAccess
    /// A modifier stayed down past the wait: ⌘V would arrive as ⌥⌘V or worse.
    case modifiersHeld
    /// The fallback strategy found no field or no Paste menu item.
    case strategyFailed
}

/// How the text gets into the app. ⌘V works in every app tried so far; the
/// others are for an app where it does not, and are never the default.
public enum PasteStrategy: String, Sendable, CaseIterable {
    /// The pasteboard and ⌘V on the layout's V key.
    case commandV
    /// The pasteboard and the app's Edit ▸ Paste menu item, pressed through AX.
    case menu
    /// `kAXSelectedTextAttribute` of the focused element: no pasteboard, but
    /// breaks undo and formatting in many apps.
    case accessibility
}

/// Pastes text into another app on the user's behalf, for dictation: checks
/// that the target is still the one the user spoke into, that it is not a
/// password field, waits for the hotkey's modifiers to be up, and only then
/// touches the pasteboard (`PlainPaste.paste(text:)`).
///
/// Main thread. Without the `PEREKEY_VOICE` flag nothing creates one.
@MainActor
public final class TextPaster {
    /// The longest `paste` waits for modifiers to be released.
    public static let modifierTimeout: Duration = .seconds(1)
    /// Modifiers that change what ⌘V means. Caps Lock and the keypad flag do not.
    public static let heldModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    public var strategy: PasteStrategy = .commandV

    private let plainPaste: PlainPaste
    private let readTarget: @MainActor () async -> PasteTarget?
    private let setSelectedText: @MainActor (String) async -> Bool
    private let pressPasteMenuItem: @MainActor () -> Void
    private let isTrusted: @MainActor () -> Bool
    private let isSecureInputOn: @MainActor () -> Bool
    private let modifierFlags: @MainActor () -> CGEventFlags
    private let modifierTimeout: Duration
    private let afterPaste: @MainActor () -> Void

    /// - Parameters:
    ///   - plainPaste: the app's one instance, so "Paste without formatting"
    ///     and dictation share the saved pasteboard.
    ///   - afterPaste: called after the text went in; the app tells the tap to
    ///     forget what it saw, so autoswitching leaves the pasted text alone.
    public convenience init(plainPaste: PlainPaste, afterPaste: @escaping @MainActor () -> Void) {
        let reader = PasteTargetReader()
        self.init(plainPaste: plainPaste,
                  readTarget: { await reader.current() },
                  setSelectedText: { await reader.setSelectedText($0) },
                  pressPasteMenuItem: { reader.pressPasteMenuItem() },
                  isTrusted: { AXIsProcessTrusted() },
                  isSecureInputOn: { SecureInput.isEnabled },
                  modifierFlags: { CGEventSource.flagsState(.combinedSessionState) },
                  afterPaste: afterPaste)
    }

    /// The closures replace the system in tests.
    init(plainPaste: PlainPaste,
         readTarget: @escaping @MainActor () async -> PasteTarget?,
         setSelectedText: @escaping @MainActor (String) async -> Bool = { _ in false },
         pressPasteMenuItem: @escaping @MainActor () -> Void = {},
         isTrusted: @escaping @MainActor () -> Bool = { true },
         isSecureInputOn: @escaping @MainActor () -> Bool,
         modifierFlags: @escaping @MainActor () -> CGEventFlags,
         modifierTimeout: Duration = TextPaster.modifierTimeout,
         afterPaste: @escaping @MainActor () -> Void)
    {
        self.plainPaste = plainPaste
        self.readTarget = readTarget
        self.setSelectedText = setSelectedText
        self.pressPasteMenuItem = pressPasteMenuItem
        self.isTrusted = isTrusted
        self.isSecureInputOn = isSecureInputOn
        self.modifierFlags = modifierFlags
        self.modifierTimeout = modifierTimeout
        self.afterPaste = afterPaste
    }

    /// The target to paste into later. Read when the user starts speaking;
    /// nil without Accessibility or when the app does not answer in time.
    public func captureTarget() async -> PasteTarget? {
        await readTarget()
    }

    /// Pastes `text` into `target` if it is still focused.
    ///
    /// In order: the modifiers of the hotkey are up (or `.failed(.modifiersHeld)`);
    /// the focus is still `target` (or `.targetChanged`); neither Secure Input
    /// nor a password field (or `.secureField`). Only then is the pasteboard
    /// touched, and it comes back by itself (`PlainPaste`). A nil `target`
    /// skips the target check: the start had nothing to compare with.
    ///
    /// The caller keeps `text` for "Paste again" and decides about history.
    public func paste(_ text: String, into target: PasteTarget?) async -> PasteResult {
        guard !text.isEmpty else { return .failed(.emptyText) }
        guard isTrusted() else { return .failed(.noAccess) }
        guard await Self.waitForRelease(of: Self.heldModifiers, flags: modifierFlags, timeout: modifierTimeout)
        else { return .failed(.modifiersHeld) }
        let current = await readTarget()
        if let target {
            guard let current, target.isSame(as: current) else { return .targetChanged }
        }
        // Right before the paste: the read above may have taken a moment.
        if current?.isSecureField == true || isSecureInputOn() { return .secureField }

        switch strategy {
        case .commandV:
            plainPaste.paste(text: text)
        case .menu:
            plainPaste.paste(text: text, post: pressPasteMenuItem)
        case .accessibility:
            guard await setSelectedText(text) else { return .failed(.strategyFailed) }
        }
        afterPaste()
        return .pasted
    }

    /// Waits until none of `modifiers` is down in `flags()`. `false` after `timeout`.
    static func waitForRelease(of modifiers: CGEventFlags, flags: @MainActor () -> CGEventFlags,
                               timeout: Duration, poll: Duration = .milliseconds(10)) async -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !flags().intersection(modifiers).isEmpty {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }
}
