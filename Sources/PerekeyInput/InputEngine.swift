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
    case convertSelection
    case secureInputChanged(Bool)
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
///
/// State below the `// Tap thread` mark is touched only on the tap thread,
/// hence `@unchecked Sendable`.
public final class InputEngine: @unchecked Sendable {
    private let onMessage: @MainActor @Sendable (EngineMessage) -> Void
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

    /// Disables within a minute that make Perekey step aside, and for how long.
    private static let disablesBeforeSuspend = 3
    private static let suspendSeconds: Double = 30

    public init(machine: InputMachine, onMessage: @escaping @MainActor @Sendable (EngineMessage) -> Void) {
        self.machine = machine
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
            engine.handle(.inputLost)
        }
    }

    /// Accessibility was revoked: drop the taps and wait for access again.
    public func accessRevoked() {
        perform { engine in
            engine.removeTaps()
            engine.handle(.inputLost)
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
        return result
    }

    private func pointer(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let time = Self.now
        switch type.rawValue {
        case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
            tapDisabled(type, at: time)
        case 1, 3, 25:
            handle(.click(time: time))
        default:
            handle(.scroll(time: time))
        }
        return Unmanaged.passUnretained(event)
    }

    private func tapDisabled(_ type: CGEventType, at time: Double) {
        disables = disables.filter { time - $0 < 60 } + [time]
        log.error("Event tap disabled (\(type.rawValue, privacy: .public)), \(self.disables.count, privacy: .public) in the last minute")
        handle(.inputLost)
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
            // The buffer believes the word was retyped; it was not.
            handle(.inputLost)
            return
        }
        TextSink.post(retype)
        handle(.retypePosted(seq: retype.seq, time: Self.now))
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
                }
                toMain(.select(id, then: then))
            case let .retype(retype):
                postIfPending(retype)
            case .releaseHeld:
                let events = held
                held.removeAll()
                let mark = SyntheticMark.replayed.userData
                for event in events {
                    event.setIntegerValueField(.eventSourceUserData, value: mark)
                    event.post(tap: .cghidEventTap)
                }
            case let .scheduleDeadline(at):
                scheduleDeadline(at: at)
            case let .autoswitchChanged(on):
                toMain(.autoswitchChanged(on))
            case let .refused(refusal):
                toMain(.refused(refusal))
            case .convertSelection:
                toMain(.convertSelection)
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
