// SPDX-License-Identifier: GPL-3.0-or-later

import Carbon
import CoreGraphics
import Foundation
import os
import PerekeyCore

/// What the engine reports to the main thread.
public enum EngineMessage: Sendable {
    case tapState(TapState)
    /// Select this layout on the main thread (Text Input Sources are main-only),
    /// then hand `then` back with `InputEngine.post(_:)`.
    case select(LayoutID, then: Retype?)
    case autoswitchChanged(Bool)
    case refused(Refusal)
    /// Read the selection (`SelectionReader`) and answer with
    /// `send(.selectionRead(seq:text:viaAccessibility:))`, empty if nothing is
    /// selected. User input is held until then.
    case convertSelection(seq: UInt32)
    case secureInputChanged(Bool)
    /// Paste the pasteboard as plain text (`PlainPaste`), on the main thread.
    case pastePlain
    /// A retype was posted: the correction sound plays. `original` is the text
    /// it replaced and `text` the new one, for the hint. `origin` says who
    /// asked: an automatic switch has its own hint (`corrected`), a manual
    /// retype names the shortcut that ran. `decision` is what automatic
    /// switching made of the word, for «why?». Never stored or logged.
    case retyped(original: String, text: String, origin: Retype.Origin, decision: Classifier.Decision?)
    /// An automatic switch was posted (`Effect.corrected`): show the hint.
    case corrected(Correction)
    /// The correction with this `seq` was undone: hide its hint.
    case correctionUndone(seq: UInt32)
    /// The undo of the correction with this `seq` was cancelled by the caret
    /// check: the text stays corrected and cannot be undone. Hide its hint.
    case correctionUndoFailed(seq: UInt32)
    /// The user undid an automatic switch: learn the word, as typed.
    case learned(String)
    /// A word typed with Caps Lock on by mistake was corrected: turn it off
    /// (`CapsLockState.turnOff`).
    case capsLockOff
}

public enum TapState: Hashable, Sendable {
    /// No Accessibility access yet; retrying once per second.
    case waitingForAccess
    case running
    /// The system kept disabling the tap (callback too slow, or the system
    /// under load). Perekey steps aside for a while instead of fighting it.
    case suspended
}

/// The event taps and the input logic, on a thread of their own.
///
/// - **Tap thread** (`Thread` + `CFRunLoopRun`, QoS userInteractive): both
///   taps, the `InputMachine` and the held events. Everything here touches
///   only memory: no AX, no TIS, no pasteboard, no disk, no locks the main
///   thread holds. A hung callback freezes the whole system's keyboard.
/// - **Into the tap thread:** `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`.
/// - **Out:** `DispatchQueue.main.async` with an `EngineMessage`.
/// - **Pre-Backspace check:** a word retype asks `TextProbe`, on its AX thread,
///   whether the text before the caret is the word, while the main thread
///   selects the target layout. The retype is posted once both are done, or
///   cancelled on a mismatch. No AX answer means post anyway (`CaretCheck`).
/// - **Replays:** events the machine held are posted again, marked
///   `.replayed`. User keys that reach the tap before the last of them wait
///   in `ReplayGate` and follow as the next replayed batch.
///
/// State below the `// Tap thread` mark is touched only on the tap thread,
/// hence `@unchecked Sendable`.
public final class InputEngine: @unchecked Sendable {
    private let onMessage: @MainActor @Sendable (EngineMessage) -> Void
    private let textProbe: TextProbe?
    private let started = DispatchSemaphore(value: 0)
    private let log = Logger(subsystem: "app.perekey", category: "engine")

    // Tap thread
    private var runLoop: CFRunLoop?
    private var machine: InputMachine
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var mouseTap: CFMachPort?
    private var mouseSource: CFRunLoopSource?
    private var retryTimer: CFRunLoopTimer?
    private var deadlineTimer: CFRunLoopTimer?
    private var held: [CGEvent] = []
    private var secureInput = false
    private var disables: [Double] = []
    private var resumeTimer: CFRunLoopTimer?
    private var check: CaretCheckState?
    /// User events waiting behind replayed ones still in flight.
    private var replays = ReplayGate<CGEvent>()
    private var replayTimer: CFRunLoopTimer?
    /// The hint's button in CG global coordinates, while the hint shows.
    private var hintButton: CGRect?

    /// The pre-Backspace check of the retype with `seq`.
    private struct CaretCheckState {
        var seq: UInt32
        var started: Double
        var verdict: CaretCheck.Verdict?
        /// The retype, once its layout is selected, waiting for the verdict.
        var waiting: Retype?
    }

    /// Disables within a minute that make Perekey step aside, and for how long.
    private static let disablesBeforeSuspend = 3
    private static let suspendSeconds: Double = 30

    /// - Parameter textProbe: checks the text before the caret before a
    ///   word's Backspaces, and replaces selections for `Retype.viaAccessibility`.
    ///   Without it, retypes are posted unchecked.
    public init(machine: InputMachine, textProbe: TextProbe? = nil,
                onMessage: @escaping @MainActor @Sendable (EngineMessage) -> Void)
    {
        self.machine = machine
        self.textProbe = textProbe
        self.onMessage = onMessage
    }

    // MARK: - Main thread API

    public func start() {
        let thread = Thread { [self] in threadMain() }
        thread.name = "app.perekey.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    /// Delivers a non-key event: layouts, focus, settings, input lost.
    public func send(_ event: InputEvent) {
        perform { $0.handle(event) }
    }

    /// Posts a retype after the main thread selected its layout. Dropped if
    /// the fence was released meanwhile: its Backspaces would erase what the
    /// user typed since.
    public func post(_ retype: Retype) {
        perform { $0.postIfPending(retype) }
    }

    /// Undoes the automatic switch with this `Correction.seq`, as the hint's
    /// Undo button asks. Does nothing once the user has typed on, clicked
    /// elsewhere, or a newer switch came.
    public func undoLastCorrection(seq: UInt32) {
        perform { $0.handle(.undoLastCorrection(seq: seq, time: Self.now)) }
    }

    /// Where the hint's button is, in CG global coordinates (top-left origin
    /// of the main display), or nil once the hint is gone. A click there is
    /// `.click(onHint: true)`: it keeps the correction undoable. The frame
    /// goes into the tap thread like any other block: the hint appears long
    /// before anyone can click it.
    public func setHintButtonFrame(_ frame: CGRect?) {
        perform { $0.hintButton = frame }
    }

    /// The main thread could not select the retype's layout.
    public func cancel(_ retype: Retype) {
        send(.retypeCancelled(seq: retype.seq))
    }

    /// After wake, unlock or a session switch: make sure the taps work and
    /// forget what may have been missed. A tap disabled after sleep silently
    /// turns the whole product off.
    public func checkTaps() {
        perform { engine in
            // A tap can come back invalid after sleep; enabling it does nothing then.
            if let tap = engine.keyboardTap, !CFMachPortIsValid(tap) { engine.removeTaps() }
            if let tap = engine.mouseTap, !CFMachPortIsValid(tap) { engine.removeTaps() }
            if engine.resumeTimer == nil {
                for tap in [engine.keyboardTap, engine.mouseTap].compactMap({ $0 }) where !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            if engine.keyboardTap == nil { engine.createTapsOrRetry() }
            engine.inputLost()
        }
    }

    /// Accessibility was revoked: drop the taps and wait for access again.
    public func accessRevoked() {
        perform { engine in
            engine.removeTaps()
            engine.inputLost()
            engine.createTapsOrRetry()
        }
    }

    private func perform(_ block: @escaping @Sendable (InputEngine) -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in block(self) }
        CFRunLoopWakeUp(runLoop)
    }

    private func toMain(_ message: EngineMessage) {
        let onMessage = onMessage
        DispatchQueue.main.async { onMessage(message) }
    }

    // MARK: - Tap thread

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        // Keeps CFRunLoopRun from returning while no tap or timer exists yet.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        createTapsOrRetry()
        CFRunLoopRun()
    }

    private static var now: Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private func createTapsOrRetry() {
        if createTaps() {
            if let retryTimer { CFRunLoopTimerInvalidate(retryTimer) }
            retryTimer = nil
            toMain(.tapState(.running))
            return
        }
        toMain(.tapState(.waitingForAccess))
        guard retryTimer == nil else { return }
        // Ticks only while access is missing; once the taps exist, nothing ticks.
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1, 1, 0, 0) {
            [self] _ in
            guard createTaps() else { return }
            if let retryTimer { CFRunLoopTimerInvalidate(retryTimer) }
            retryTimer = nil
            toMain(.tapState(.running))
        }
        retryTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    private func createTaps() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if keyboardTap == nil {
            let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                | 1 << CGEventType.flagsChanged.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    Unmanaged<InputEngine>.fromOpaque(refcon!).takeUnretainedValue().keyboard(type, event)
                },
                userInfo: refcon
            ) else { return false }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            keyboardTap = tap
            keyboardSource = source
        }
        if mouseTap == nil {
            // Listen only: an active mouse tap would delay all pointer input.
            // 1, 3, 25 mouse down; 22 scroll; 18 rotate; 30 magnify; 31 swipe.
            // Not 29, 19, 20: they flow while fingers merely rest on the
            // trackpad, and Shift would never count on a laptop (spike S0).
            let types: [UInt64] = [1, 3, 25, 22, 18, 30, 31]
            let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1 }
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    Unmanaged<InputEngine>.fromOpaque(refcon!).takeUnretainedValue().pointer(type, event)
                },
                userInfo: refcon
            ) {
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                mouseTap = tap
                mouseSource = source
            }
        }
        return true
    }

    private func removeTaps() {
        for (tap, source) in [(keyboardTap, keyboardSource), (mouseTap, mouseSource)] {
            guard let tap else { continue }
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        keyboardTap = nil
        keyboardSource = nil
        mouseTap = nil
        mouseSource = nil
    }

    private func keyboard(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let time = Self.now
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapDisabled(type, at: time)
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        let origin = EventOrigin(mark: SyntheticMark(userData: event.getIntegerValueField(.eventSourceUserData)))
        if origin == .user, type != .keyUp {
            // Key presses do not arrive under Secure Input, modifier changes do.
            let secure = IsSecureEventInputEnabled()
            if secure != secureInput {
                secureInput = secure
                handle(.secureInputChanged(secure))
                toMain(.secureInputChanged(secure))
            }
        }

        switch origin {
        case .user:
            // Replays still on their way would come after this key: it waits
            // for them and goes out behind them, marked replayed.
            if replays.mustWait(at: time) {
                if let copy = event.copy() { holdBehindReplays(copy, at: time) }
                return nil
            }
        case .replayed:
            replays.replayedSeen()
        case .own:
            break
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let input: InputEvent = switch type {
        case .flagsChanged:
            .flagsChanged(keyCode: keyCode, flags: flags, origin: origin, time: time)
        default:
            .key(KeyEvent(type == .keyDown ? .down : .up, keyCode: keyCode, flags: flags,
                          isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, origin: origin),
                 time: time)
        }

        let output = machine.handle(input)
        let result: Unmanaged<CGEvent>?
        switch output.disposition {
        case .pass:
            result = Unmanaged.passUnretained(event)
        case .drop:
            result = nil
        case .hold:
            if let copy = event.copy() { held.append(copy) }
            result = nil
        }
        // The disposition first: a held event may be released by the same output.
        execute(output.effects)
        if origin == .replayed { postReplayed(replays.takeReady(), at: time) }
        return result
    }

    private func holdBehindReplays(_ event: CGEvent, at time: Double) {
        let first = replays.waiting.isEmpty
        replays.hold(event)
        if first, let deadline = replays.deadline { scheduleReplayCheck(at: deadline, now: time) }
    }

    /// Posts events again, marked `.replayed`. Counted ones are expected back
    /// through the tap; keys typed meanwhile wait for them.
    private func postReplayed(_ events: [CGEvent], at time: Double, counted: Bool = true) {
        guard !events.isEmpty else { return }
        let mark = SyntheticMark.replayed.userData
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: mark)
            event.post(tap: .cghidEventTap)
        }
        if counted { replays.posted(events.count, at: time) }
    }

    /// Replays that never came back must not hold the keyboard for long.
    private func scheduleReplayCheck(at deadline: Double, now: Double) {
        if let replayTimer { CFRunLoopTimerInvalidate(replayTimer) }
        let fire = CFAbsoluteTimeGetCurrent() + max(0, deadline - now)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fire, 0, 0, 0) { [self] _ in
            replayTimer = nil
            let time = Self.now
            if let late = replays.expire(at: time) {
                log.error("\(late.count, privacy: .public) keys waited for replays that did not come back")
                postReplayed(late, at: time, counted: false)
            } else if let deadline = replays.deadline {
                scheduleReplayCheck(at: deadline, now: time)
            }
        }
        replayTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }

    /// Events may have been lost: the machine lets its held events go, then
    /// the keys that waited for replays follow them.
    private func inputLost() {
        let waiting = replays.reset()
        handle(.inputLost)
        postReplayed(waiting, at: Self.now)
    }

    private func pointer(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let time = Self.now
        switch type.rawValue {
        case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
            tapDisabled(type, at: time)
        case 1, 3, 25:
            let onHint = hintButton?.contains(event.location) ?? false
            handle(.click(time: time, onHint: onHint))
        default:
            handle(.scroll(time: time))
        }
        return Unmanaged.passUnretained(event)
    }

    private func tapDisabled(_ type: CGEventType, at time: Double) {
        disables = disables.filter { time - $0 < 60 } + [time]
        log.error("Event tap disabled (\(type.rawValue, privacy: .public)), \(self.disables.count, privacy: .public) in the last minute")
        inputLost()
        guard resumeTimer == nil else { return }
        if disables.count >= Self.disablesBeforeSuspend {
            // Re-enabling at once would loop: disabled, enabled, disabled.
            toMain(.tapState(.suspended))
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + Self.suspendSeconds, 0, 0, 0
            ) { [self] _ in
                resumeTimer = nil
                disables.removeAll()
                enableTaps()
                toMain(.tapState(.running))
            }
            resumeTimer = timer
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
            return
        }
        enableTaps()
    }

    /// The callback cannot tell which tap was disabled: enable both.
    private func enableTaps() {
        for tap in [keyboardTap, mouseTap].compactMap({ $0 }) where !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func postIfPending(_ retype: Retype) {
        guard machine.pendingRetypeSeq == retype.seq else {
            log.error("Retype \(retype.seq, privacy: .public) arrived after its fence; not posted")
            // The buffer believes the word was retyped; it was not. No event
            // was lost, so replays on their way still keep their order.
            handle(.inputLost)
            return
        }
        if let pending = check, pending.seq == retype.seq {
            guard let verdict = pending.verdict else {
                check?.waiting = retype
                return
            }
            check = nil
            if verdict == .mismatch {
                log.info("Retype \(retype.seq, privacy: .public) cancelled: the text before the caret differs")
                handle(.retypeCancelled(seq: retype.seq))
                return
            }
        }
        if retype.viaAccessibility, let textProbe {
            textProbe.replaceSelection(with: retype.text) { [self] done in
                perform { $0.replacedViaAccessibility(retype, done: done) }
            }
            return
        }
        TextSink.post(retype)
        handle(.retypePosted(seq: retype.seq, time: Self.now))
        toMainRetyped(retype)
    }

    private func toMainRetyped(_ retype: Retype) {
        toMain(.retyped(original: retype.expected, text: retype.text, origin: retype.origin,
                        decision: retype.decision))
    }

    private func replacedViaAccessibility(_ retype: Retype, done: Bool) {
        guard machine.pendingRetypeSeq == retype.seq else { return }
        if done {
            handle(.retypePosted(seq: retype.seq, time: Self.now))
            toMainRetyped(retype)
        } else {
            log.error("Retype \(retype.seq, privacy: .public): AX did not replace the selection")
            handle(.retypeCancelled(seq: retype.seq))
        }
    }

    /// Starts the pre-Backspace check of a word retype on the AX thread. Runs
    /// alongside the layout selection on main, so it adds latency only when AX
    /// answers slower than TIS.
    private func beginCheck(_ retype: Retype) {
        guard retype.deleteCount > 0, !retype.expected.isEmpty, let textProbe else { return }
        let seq = retype.seq
        check = CaretCheckState(seq: seq, started: Self.now)
        textProbe.checkBeforeCaret(expected: retype.expected) { [self] verdict in
            perform { $0.checkFinished(seq: seq, verdict: verdict) }
        }
    }

    private func checkFinished(seq: UInt32, verdict: CaretCheck.Verdict) {
        guard let pending = check, pending.seq == seq else { return }
        // Numbers only: the text never reaches the log.
        let ms = (Self.now - pending.started) * 1000
        log.info("Caret check \(seq, privacy: .public): \(String(describing: verdict), privacy: .public) in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
        check?.verdict = verdict
        if let waiting = pending.waiting {
            check?.waiting = nil
            postIfPending(waiting)
        }
    }

    private func handle(_ event: InputEvent) {
        execute(machine.handle(event).effects)
    }

    private func execute(_ effects: [Effect]) {
        var index = effects.startIndex
        while index < effects.endIndex {
            switch effects[index] {
            case let .selectLayout(id):
                // A retype right after its layout selection waits for the main
                // thread to select first, then comes back here to be posted.
                var then: Retype?
                if index + 1 < effects.endIndex, case let .retype(retype) = effects[index + 1] {
                    then = retype
                    index += 1
                    beginCheck(retype)
                }
                toMain(.select(id, then: then))
            case let .retype(retype):
                beginCheck(retype)
                postIfPending(retype)
            case .releaseHeld:
                let events = held
                held.removeAll()
                postReplayed(events, at: Self.now)
            case let .scheduleDeadline(at):
                scheduleDeadline(at: at)
            case let .autoswitchChanged(on):
                toMain(.autoswitchChanged(on))
            case .pastePlain:
                toMain(.pastePlain)
            case let .corrected(correction):
                toMain(.corrected(correction))
            case let .correctionUndone(seq):
                toMain(.correctionUndone(seq: seq))
            case let .correctionUndoFailed(seq):
                toMain(.correctionUndoFailed(seq: seq))
            case let .learned(word):
                toMain(.learned(word))
            case .capsLockOff:
                toMain(.capsLockOff)
            case let .refused(refusal):
                toMain(.refused(refusal))
            case let .convertSelection(seq):
                toMain(.convertSelection(seq: seq))
            }
            index += 1
        }
    }

    private func scheduleDeadline(at deadline: Double) {
        if let deadlineTimer { CFRunLoopTimerInvalidate(deadlineTimer) }
        let fire = CFAbsoluteTimeGetCurrent() + max(0, deadline - Self.now)
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, fire, 0, 0, 0) { [self] _ in
            deadlineTimer = nil
            handle(.deadline(time: Self.now))
        }
        deadlineTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .commonModes)
    }
}
