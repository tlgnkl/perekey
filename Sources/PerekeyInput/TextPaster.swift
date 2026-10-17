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
    /// Secure Input came on while the text was typed (`.keystrokes`):
    /// typing stopped part way, and the start of the text went in. Not to
    /// be pasted again whole, and kept out of the history.
    case secureInputWhileTyping(owner: SecureInputOwner)
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
    /// Typing (`.keystrokes`) stopped part way: the focus moved, the user
    /// pressed a key or a modifier, or the task was cancelled. The start of
    /// the text may be in the target. Not to be pasted again whole.
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
    private let postStroke: @MainActor (_ stroke: String, _ source: CGEventSource?, _ mark: SyntheticMark) -> Void
    private let sleep: @MainActor (Duration) async -> Void
    private let tapRunning: @MainActor () -> Bool
    private let typingChanged: @MainActor (_ typing: Bool) -> Void
    private let afterPaste: @MainActor () -> Void

    /// The typing in progress, if any (`.keystrokes`).
    private var typing: Typing?
    /// The last checkpoint posted, by any typing: an older typing's
    /// checkpoint is below the current one's.
    private var checkpoint: UInt32 = 0

    @MainActor
    private final class Typing {
        /// The highest checkpoint the tap saw.
        var seen: UInt32 = 0
        /// The user pressed a key, or a newer typing began.
        var stopped = false
        /// The task was cancelled while it waited for a checkpoint.
        var cancelled = false
        /// Checkpoints come back: false once one did not, and the tap is
        /// not waited for any more.
        var acknowledges = true
        /// The wait for a checkpoint, and which one.
        var waiter: (seq: UInt32, continuation: CheckedContinuation<Void, Never>)?

        /// Ends the wait once its checkpoint was seen, the typing stopped or
        /// was cancelled, or its time ran out (`timedOut` names its checkpoint).
        func wake(timedOut: UInt32? = nil) {
            guard let waiter else { return }
            if let timedOut {
                guard timedOut == waiter.seq else { return }
                acknowledges = false
            } else if seen < waiter.seq, !stopped, !cancelled {
                return
            }
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// - Parameters:
    ///   - plainPaste: the app's one instance, so "Paste without formatting"
    ///     and dictation share the saved pasteboard.
    ///   - tapRunning: Perekey's event tap runs. Without it typing would
    ///     not see the user's keys nor its own checkpoints: ⌘V instead.
    ///   - typingChanged: typing starts or ends; the app tells the tap
    ///     (`InputEvent.dictationTyping`), after `.inputLost` at the start.
    ///   - afterPaste: called after the text went in; the app tells the tap to
    ///     forget what it saw, so autoswitching leaves the pasted text alone.
    public convenience init(plainPaste: PlainPaste,
                            tapRunning: @escaping @MainActor () -> Bool = { true },
                            typingChanged: @escaping @MainActor (_ typing: Bool) -> Void = { _ in },
                            afterPaste: @escaping @MainActor () -> Void)
    {
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
                  postStroke: { TypedText.post($0, source: $1, mark: $2) },
                  sleep: { try? await Task.sleep(for: $0) },
                  tapRunning: tapRunning,
                  typingChanged: typingChanged,
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
         postStroke: @escaping @MainActor (_ stroke: String, _ source: CGEventSource?, _ mark: SyntheticMark)
             -> Void = { _, _, _ in },
         sleep: @escaping @MainActor (Duration) async -> Void = { _ in },
         tapRunning: @escaping @MainActor () -> Bool = { true },
         typingChanged: @escaping @MainActor (_ typing: Bool) -> Void = { _ in },
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
        self.tapRunning = tapRunning
        self.typingChanged = typingChanged
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
            if let stopped = await type(text, into: current) { return stopped }
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
    /// app types `text` and Perekey's tap runs, else ⌘V.
    func strategy(for text: String, pid: pid_t) -> PasteStrategy {
        if let strategy { return strategy }
        let bundleID = bundleID(pid)
        guard insertion(bundleID).types(text, bundleID: bundleID), tapRunning() else { return .commandV }
        return .keystrokes
    }

    /// The tap saw the checkpoint `seq` of a typing (`EngineMessage.typedSeen`).
    public func typedSeen(seq: UInt32) {
        guard let typing, seq > typing.seen else { return }
        typing.seen = seq
        typing.wake()
    }

    /// The user pressed a key while dictation typed (`EngineMessage.typingInterrupted`).
    public func typingInterrupted() {
        typing?.stopped = true
        typing?.wake()
    }

    /// Types `text` into `target`, already checked; nil when all of it went
    /// and the tap saw the last stroke.
    ///
    /// It stops, `.failed(.interrupted)`, when the task is cancelled or the
    /// user presses a key (`typingInterrupted`), and at a pause when a
    /// modifier is down (⌘ and the next stroke would be ⌘A), another app is
    /// in front, or AX, at most every `typingCheck`, names another field. An
    /// app busy with the keys may not answer AX: that alone does not stop
    /// it. Secure Input at a pause: `.secureInputWhileTyping`. After the last stroke
    /// has passed the tap, the focus once more: it may have moved while the
    /// strokes were on their way.
    private func type(_ text: String, into target: PasteTarget) async -> PasteResult? {
        let typing = Typing()
        self.typing?.stopped = true
        self.typing?.wake()
        self.typing = typing
        typingChanged(true)
        defer { end(typing) }
        let source = CGEventSource(stateID: .privateState)
        let clock = ContinuousClock()
        var checked = clock.now
        let strokes = TypedText.strokes(text)
        var count = 0
        for (index, stroke) in strokes.enumerated() {
            if Task.isCancelled || typing.stopped { return stop(typing, after: index) }
            let last = index == strokes.count - 1
            var mark = SyntheticMark.typed(seq: 0, ack: false)
            if last || (index + 1).isMultiple(of: TypedText.ackEvery) {
                checkpoint &+= 1
                mark = .typed(seq: checkpoint, ack: true)
            }
            postStroke(stroke, source, mark)
            count += 1
            let pause = TypedText.pause(after: stroke, count: count)
            if pause != nil { count = 0 }
            if let pause, !last { await sleep(pause) }
            if case let .typed(seq, ack: true) = mark { await waitUntilSeen(seq, typing) }
            guard pause != nil || last else { continue }
            // Keys and modifiers after the last stroke come after the text.
            if !last {
                if Task.isCancelled || typing.stopped { return stop(typing, after: index + 1) }
                if !modifierFlags().intersection(Self.heldModifiers).isEmpty { return stop(typing, after: index + 1) }
                if let owner = secureInputOwner() {
                    return stop(typing, after: index + 1, .secureInputWhileTyping(owner: owner))
                }
            }
            var moved = frontmostPID() != target.pid
            if !moved, last || clock.now - checked >= Self.typingCheck {
                checked = clock.now
                if let now = await readTarget(target.pid) { moved = !target.isSame(as: now) }
            }
            if moved { return stop(typing, after: index + 1) }
        }
        return nil
    }

    /// Typing stopped after `posted` strokes. Some of the text went in: the
    /// tap must leave it alone too.
    private func stop(_ typing: Typing, after posted: Int, _ result: PasteResult = .failed(.interrupted))
        -> PasteResult
    {
        end(typing)
        if posted > 0 { afterPaste() }
        return result
    }

    /// The tap judges the user's keys again, unless a newer typing runs.
    private func end(_ typing: Typing) {
        guard self.typing === typing else { return }
        self.typing = nil
        typingChanged(false)
    }

    /// Waits until the tap saw checkpoint `seq`, the typing stopped or was
    /// cancelled, or `seenTimeout` passed. A checkpoint that does not come
    /// (the tap is suspended meanwhile) is the last one waited for.
    private func waitUntilSeen(_ seq: UInt32, _ typing: Typing) async {
        guard typing.acknowledges, typing.seen < seq, !typing.stopped, !Task.isCancelled else { return }
        let sleep = self.sleep
        let timeout = Task {
            await sleep(Self.seenTimeout)
            if !Task.isCancelled { typing.wake(timedOut: seq) }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { typing.waiter = (seq, $0) }
        } onCancel: {
            Task { @MainActor in
                typing.cancelled = true
                typing.wake()
            }
        }
        timeout.cancel()
    }

    /// How often typing reads the focus through AX.
    static let typingCheck: Duration = .milliseconds(100)
    /// How long a checkpoint may take to pass the tap.
    static let seenTimeout: Duration = .milliseconds(500)

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
