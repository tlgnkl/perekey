// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import PerekeyCore

/// What became of a paste.
public enum PasteResult: Equatable, Sendable {
    case pasted
    /// The user moved to another app, window or field: nothing was pasted and
    /// the pasteboard was not touched.
    case targetChanged
    /// The focus is a password field: nothing was pasted, and the text must
    /// not go to the history either.
    case secureField
    /// Secure Input is on in some process while the focus is no password
    /// field, e.g. Terminal's "Secure Keyboard Entry" or a stuck login
    /// window: nothing was pasted. Keystrokes are hidden from Perekey, not the
    /// text from the user, so the text may stay for "Paste again".
    case secureInput(owner: SecureInputOwner)
    case failed(PasteFailure)
}

public enum PasteFailure: Equatable, Sendable {
    case emptyText
    /// Without Accessibility no key or AX action reaches another app.
    case noAccess
    /// A modifier stayed down past the wait: ⌘V would arrive as ⌥⌘V or worse.
    case modifiersHeld
    /// The fallback strategy found no field or no Paste menu item, or the app
    /// refused: certainly nothing was pasted.
    case strategyFailed
    /// The app did not answer the fallback strategy in time: the text may
    /// still arrive. Offer "Paste again" rather than pasting again by itself.
    case timedOut
    /// The focus moved while the text was typed (`.keystrokes`): typing
    /// stopped, and the start of the text may be in the old target. Not to
    /// be pasted again whole.
    case interrupted
}

/// How the text gets into the app. ⌘V works in every app tried so far; the
/// others are for an app where it does not. Each paste picks one
/// (`TextPaster.insertion`): ⌘V, or `.keystrokes` for a terminal.
public enum PasteStrategy: String, Sendable, CaseIterable {
    /// The pasteboard and ⌘V on the layout's V key.
    case commandV
    /// The pasteboard and the app's Edit ▸ Paste menu item, pressed through AX.
    case menu
    /// `kAXSelectedTextAttribute` of the focused element: no pasteboard, but
    /// breaks undo and formatting in many apps. Safari and Chromium text
    /// areas answer "success" and insert nothing: not for web content.
    case accessibility
    /// Key events that carry the text (`TypedText`), no pasteboard: for a
    /// terminal, where a paste arrives bracketed and may be folded.
    case keystrokes
}

/// Pastes text into another app on the user's behalf, for dictation: checks
/// that the target is still the one the user spoke into, that it is not a
/// password field, waits for the hotkey's modifiers to be up, and only then
/// touches the pasteboard (`PlainPaste.paste(text:)`).
///
/// Main thread. Without the `PEREKEY_VOICE` flag nothing creates one.
@MainActor
public final class TextPaster {
    /// How long the target app gets to read the text before the pasteboard
    /// comes back. Longer than "Paste without formatting": a dictation often
    /// ends in an app busy with its own work. An app that hangs for longer
    /// reads the restored pasteboard instead.
    public static let restoreDelay: Duration = .milliseconds(1200)
    /// The longest `paste` waits for modifiers to be released.
    public static let modifierTimeout: Duration = .seconds(1)
    /// Modifiers that change what ⌘V means. Caps Lock and the keypad flag do not.
    public static let heldModifiers: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn,
    ]

    /// The strategy of every paste, for tests and the e2e run; nil picks one
    /// per paste from `insertion`.
    public var strategy: PasteStrategy?

    /// «Вставка диктовки» for the app with this bundle ID. The app reads it
    /// from the voice settings.
    public var insertion: @MainActor (_ bundleID: String?) -> DictationInsertion = { _ in .automatic }

    /// Reads the text before the caret of a field; nothing without the AX reader.
    private var readContext: @MainActor (AXElementRef) async -> String? = { _ in nil }

    private let plainPaste: PlainPaste
    private let readTarget: @MainActor (_ frontmostPID: pid_t?) async -> PasteTarget?
    private let frontmostPID: @MainActor () -> pid_t?
    private let setSelectedText: @MainActor (String, AXElementRef) async -> AXActionOutcome
    private let pressPasteMenuItem: @MainActor (_ pid: pid_t) async -> AXActionOutcome
    private let isTrusted: @MainActor () -> Bool
    private let secureInputOwner: @MainActor () -> SecureInputOwner?
    private let modifierFlags: @MainActor () -> CGEventFlags
    private let modifierTimeout: Duration
    private let bundleID: @MainActor (_ pid: pid_t) -> String?
    private let postStroke: @MainActor (_ stroke: String, _ source: CGEventSource?) -> Void
    private let sleep: @MainActor (Duration) async -> Void
    private let afterPaste: @MainActor () -> Void

    /// - Parameters:
    ///   - plainPaste: the app's one instance, so "Paste without formatting"
    ///     and dictation share the saved pasteboard.
    ///   - afterPaste: called after the text went in; the app tells the tap to
    ///     forget what it saw, so autoswitching leaves the pasted text alone.
    public convenience init(plainPaste: PlainPaste, afterPaste: @escaping @MainActor () -> Void) {
        let reader = PasteTargetReader()
        self.init(plainPaste: plainPaste,
                  readTarget: { await reader.current(frontmostPID: $0) },
                  frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                  setSelectedText: { await reader.setSelectedText($0, in: $1) },
                  pressPasteMenuItem: { await reader.pressPasteMenuItem(pid: $0) },
                  isTrusted: { AXIsProcessTrusted() },
                  secureInputOwner: {
                      SecureInput.isEnabled ? SecureInput.owner(pid: SecureInput.ownerPID()) : nil
                  },
                  modifierFlags: { CGEventSource.flagsState(.combinedSessionState) },
                  bundleID: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
                  postStroke: { TypedText.post($0, source: $1) },
                  sleep: { try? await Task.sleep(for: $0) },
                  afterPaste: afterPaste)
        readContext = { await reader.textBeforeCaret(in: $0) }
    }

    /// The closures replace the system in tests.
    init(plainPaste: PlainPaste,
         readTarget: @escaping @MainActor (_ frontmostPID: pid_t?) async -> PasteTarget?,
         frontmostPID: @escaping @MainActor () -> pid_t? = { nil },
         setSelectedText: @escaping @MainActor (String, AXElementRef) async -> AXActionOutcome = { _, _ in .notDone },
         pressPasteMenuItem: @escaping @MainActor (_ pid: pid_t) async -> AXActionOutcome = { _ in .notDone },
         isTrusted: @escaping @MainActor () -> Bool = { true },
         secureInputOwner: @escaping @MainActor () -> SecureInputOwner? = { nil },
         modifierFlags: @escaping @MainActor () -> CGEventFlags,
         modifierTimeout: Duration = TextPaster.modifierTimeout,
         bundleID: @escaping @MainActor (_ pid: pid_t) -> String? = { _ in nil },
         postStroke: @escaping @MainActor (_ stroke: String, _ source: CGEventSource?) -> Void = { _, _ in },
         sleep: @escaping @MainActor (Duration) async -> Void = { _ in },
         afterPaste: @escaping @MainActor () -> Void)
    {
        self.plainPaste = plainPaste
        self.readTarget = readTarget
        self.frontmostPID = frontmostPID
        self.setSelectedText = setSelectedText
        self.pressPasteMenuItem = pressPasteMenuItem
        self.isTrusted = isTrusted
        self.secureInputOwner = secureInputOwner
        self.modifierFlags = modifierFlags
        self.modifierTimeout = modifierTimeout
        self.bundleID = bundleID
        self.postStroke = postStroke
        self.sleep = sleep
        self.afterPaste = afterPaste
    }

    /// The target to paste into later. Read when the user starts speaking.
    /// Without an AX answer it is the frontmost app's PID alone; nil only
    /// when there is no frontmost app, and then there is nothing to paste into.
    public func captureTarget() async -> PasteTarget? {
        await currentTarget()
    }

    /// The few characters before the caret in `target`'s field: "" in an empty
    /// field or at its start, nil when the field does not tell. For the text
    /// rules, read just before the paste.
    public func textBeforeCaret(in target: PasteTarget) async -> String? {
        guard let element = target.element?.ref, !target.isSecureField else { return nil }
        return await readContext(element)
    }

    /// Pastes `text` into `target` if it is still focused.
    ///
    /// In order: the modifiers of the hotkey are up (or `.failed(.modifiersHeld)`);
    /// the focus is still `target` (or `.targetChanged`); no password field
    /// (or `.secureField`) and no Secure Input (or `.secureInput`). Only then
    /// is the pasteboard touched, and it comes back by itself (`PlainPaste`).
    /// `.keystrokes` leaves the pasteboard alone and keeps checking the
    /// target while it types (or `.failed(.interrupted)`).
    ///
    /// The caller keeps `text` for "Paste again" and decides about history.
    public func paste(_ text: String, into target: PasteTarget) async -> PasteResult {
        guard !text.isEmpty else { return .failed(.emptyText) }
        guard isTrusted() else { return .failed(.noAccess) }
        guard await Self.waitForRelease(of: Self.heldModifiers, flags: modifierFlags, timeout: modifierTimeout)
        else { return .failed(.modifiersHeld) }
        guard let current = await currentTarget(), target.isSame(as: current) else { return .targetChanged }
        // Right before the paste: the read above may have taken a moment.
        if current.isSecureField { return .secureField }
        if let owner = secureInputOwner() { return .secureInput(owner: owner) }

        switch strategy(for: text, pid: current.pid) {
        case .keystrokes:
            if let failure = await type(text, into: current) { return .failed(failure) }
        case .commandV:
            plainPaste.paste(text: text, restoreDelay: Self.restoreDelay)
        case .menu:
            // The menu of the app that was checked, not of a newer focus.
            let pid = current.pid
            let outcome = await plainPaste.paste(text: text, restoreDelay: Self.restoreDelay,
                                                 post: { await pressPasteMenuItem(pid) })
            if let failure = failure(outcome) { return .failed(failure) }
        case .accessibility:
            // The element just checked against the target: the same one, or
            // its rebuilt web twin that the captured reference no longer reaches.
            guard let element = current.element?.ref else { return .failed(.strategyFailed) }
            if let failure = failure(await setSelectedText(text, element)) { return .failed(failure) }
        }
        afterPaste()
        return .pasted
    }

    /// The fixed strategy, else `.keystrokes` where the user's choice for the
    /// app types `text`, else ⌘V.
    func strategy(for text: String, pid: pid_t) -> PasteStrategy {
        if let strategy { return strategy }
        let bundleID = bundleID(pid)
        return insertion(bundleID).types(text, bundleID: bundleID) ? .keystrokes : .commandV
    }

    /// Types `text` into `target`, already checked; nil when all of it went.
    /// Between bursts the app in front must still be the target's, and at
    /// most every `typingCheck` the focus, as far as AX answers: an app busy
    /// with the keys may not answer, and that alone does not stop typing.
    private func type(_ text: String, into target: PasteTarget) async -> PasteFailure? {
        let source = CGEventSource(stateID: .privateState)
        let clock = ContinuousClock()
        var checked = clock.now
        var count = 0
        for stroke in TypedText.strokes(text) {
            postStroke(stroke, source)
            count += 1
            guard let pause = TypedText.pause(after: stroke, count: count) else { continue }
            count = 0
            await sleep(pause)
            var moved = frontmostPID() != target.pid
            if !moved, clock.now - checked >= Self.typingCheck {
                checked = clock.now
                if let now = await readTarget(target.pid) { moved = !target.isSame(as: now) }
            }
            if moved {
                // Some of the text went in: the tap must leave it alone too.
                afterPaste()
                return .interrupted
            }
        }
        return nil
    }

    /// How often typing reads the focus through AX.
    static let typingCheck: Duration = .milliseconds(100)

    /// Nil when the strategy worked. Text that may still arrive gets
    /// `afterPaste` as well: the tap must not retype it either.
    private func failure(_ outcome: AXActionOutcome) -> PasteFailure? {
        switch outcome {
        case .done:
            return nil
        case .notDone:
            return .strategyFailed
        case .unknown:
            afterPaste()
            return .timedOut
        }
    }

    /// The AX target, or the frontmost app's PID when AX did not answer.
    private func currentTarget() async -> PasteTarget? {
        let frontmost = frontmostPID()
        if let target = await readTarget(frontmost) { return target }
        return frontmost.map(PasteTarget.app(pid:))
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
