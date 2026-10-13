// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The dictation sessions: what the hotkey, Esc and the system do in each
/// state. Pure logic; `VoiceController` carries out its outputs and feeds
/// back what came of them.
///
/// Every session has a number. Inputs that answer an output carry it, and
/// one of a session that is over is ignored: CoreML cannot be stopped in the
/// middle, so a cancelled recognition still finishes and its text is dropped.
public struct DictationMachine: Sendable {
    public typealias Session = UInt64

    /// How the session was started, and so what ends it.
    public enum Trigger: Hashable, Sendable {
        case tap
        case hold
    }

    /// What the recognized text is for.
    public enum Delivery: Hashable, Sendable {
        case paste
        /// Accessibility was revoked: no paste, the text is only kept (for
        /// "Copy" in the HUD, later in the history).
        case keep
    }

    /// Why a recording ended with its audio kept.
    public enum StopReason: Hashable, Sendable {
        /// The tap, or the hold let go.
        case trigger
        /// The hold's key up was never seen: the keys were found up.
        case holdLost
        case silence
        /// `DictationAudio.limitSeconds`.
        case limit
        /// The microphone changed, was lost or stalled.
        case deviceChanged
        /// The screen was locked or another user took the console.
        case sessionLost
        /// Secure Input went on: what was said is recognized, the paste
        /// checks the field.
        case secureInput
        case accessibilityLost
    }

    /// Why a session ended with its audio dropped.
    public enum CancelReason: Hashable, Sendable {
        case escape
        case sleep
    }

    public enum CaptureFailure: Hashable, Sendable {
        case notAuthorized
        case noMicrophone
        case other(String)
    }

    public enum State: Hashable, Sendable {
        case idle
        /// The microphone is starting; a stop or a cancel waits for it.
        case starting(Session, Trigger, pending: Pending?)
        case recording(Session, Trigger)
        case recognizing(Session, Delivery, refines: Bool)
        /// The mode's language model works on the text. A tap does nothing;
        /// Esc, a failure or the timeout paste `raw`.
        case refining(Session, Delivery, raw: String)
        case pasting(Session)
    }

    public enum Pending: Hashable, Sendable {
        case stop(StopReason)
        case cancel(CancelReason)
    }

    public enum Input: Hashable, Sendable {
        case voice(VoiceSignal)
        case captureStarted(Session)
        case captureFailed(Session, CaptureFailure)
        /// The recording ended by itself: silence, the limit, the device.
        case captureEnded(Session, StopReason)
        /// The screen was locked or the console went to another user.
        case sessionLost
        case accessibilityLost
        case sleep
        case secureInputChanged(Bool)
        case recognized(Session, RecognitionOutcome)
        case recognitionFailed(Session, String)
        /// The language model's text, checked by `OutputGuard`.
        case refined(Session, String)
        /// The language model failed, timed out, or its text did not pass
        /// `OutputGuard`: the dictation goes in as recognized.
        case refineFailed(Session)
        /// The paste is done, whatever came of it.
        case pasted(Session)
        /// Dictation is being turned off: whatever runs is dropped.
        case shutdown
        /// The session's mode has a language model step: sent once the mode
        /// is resolved, before the recording ends.
        case refinesText(Session, Bool)
    }

    /// What the HUD shows for the machine's part of a session. The level,
    /// the timer, "preparing the model" and the paste's result come from
    /// `VoiceController`.
    public enum Phase: Hashable, Sendable {
        case starting
        case recording
        case recognizing
        /// A tap while recognizing: "Still recognizing".
        case stillRecognizing
        /// The mode's language model works: "Улучшаю".
        case refining
        case pasting
        case cancelled
        /// No speech, or only phrases the stop list removed.
        case nothingHeard
        case captureFailed(CaptureFailure)
        case recognitionFailed(String)
    }

    public enum Sound: Hashable, Sendable {
        case start
        case stop
    }

    public enum Output: Hashable, Sendable {
        case startCapture(Session)
        /// Stop the microphone and keep the audio.
        case stopCapture(Session)
        /// Stop the microphone if it runs and drop the session's audio and work.
        case discard(Session)
        case recognize(Session, Delivery)
        /// Run the mode's language model on the text.
        case refine(Session, String)
        /// Stop the language model; its answer is not waited for.
        case stopRefining(Session)
        case paste(Session, String)
        /// Keep the text without pasting (`Delivery.keep`).
        case keep(Session, String)
        /// The session is on or over, the paste included: Secure Input rules
        /// apply while it is on.
        case sessionActive(Bool)
        /// The tap takes Esc (`InputEvent.voiceSession`): from the start
        /// until the paste begins. Esc cannot stop a paste, so it goes to
        /// the app again.
        case takesEscape(Bool)
        /// Check the hold's keys while a hold session starts and records.
        case watchHold(Bool)
        case sound(Sound)
        case phase(Phase)
    }

    public private(set) var state: State = .idle
    public private(set) var lastSession: Session = 0
    /// The session in progress has a language model step after recognition:
    /// set by `VoiceController` from the mode when the session starts.
    public private(set) var refines = false
    /// Secure Input is on: dictation does not start, and makes no sound or HUD.
    public private(set) var secureInput = false
    /// The tap was told to take Esc and not told otherwise yet.
    private var escapeTaken = false

    public init(secureInput: Bool = false) {
        self.secureInput = secureInput
    }

    public mutating func handle(_ input: Input) -> [Output] {
        var out: [Output] = []
        switch input {
        case let .secureInputChanged(on):
            secureInput = on
            if on { stopAny(.secureInput, &out) }
        case .sessionLost:
            stopAny(.sessionLost, &out)
        case .accessibilityLost:
            accessibilityLost(&out)
        case .sleep:
            cancelAny(.sleep, &out)
        case .shutdown:
            guard let session else { break }
            var trigger: Trigger?
            switch state {
            case let .starting(_, current, _), let .recording(_, current): trigger = current
            default: break
            }
            out.append(.discard(session))
            finish(trigger: trigger, &out)
        case let .voice(signal):
            voice(signal, &out)
        case let .refinesText(session, on):
            switch state {
            case let .starting(current, _, _), let .recording(current, _):
                if current == session { refines = on }
            default:
                break
            }
        case let .captureStarted(session):
            captureStarted(session, &out)
        case let .captureFailed(session, failure):
            guard case let .starting(current, trigger, _) = state, current == session else { break }
            finish(trigger: trigger, &out)
            out.append(.phase(.captureFailed(failure)))
        case let .captureEnded(session, reason):
            guard self.session == session else { break }
            stopAny(reason, &out)
        case let .recognized(session, outcome):
            guard case let .recognizing(current, delivery, refines) = state, current == session else { break }
            switch outcome {
            case let .text(text) where refines:
                state = .refining(session, delivery, raw: text)
                out += [.phase(.refining), .refine(session, text)]
            case let .text(text):
                deliver(session, text, delivery, &out)
            case .noSpeech, .nothingLeft:
                finish(&out)
                out.append(.phase(.nothingHeard))
            }
        case let .recognitionFailed(session, message):
            guard case let .recognizing(current, _, _) = state, current == session else { break }
            finish(&out)
            out.append(.phase(.recognitionFailed(message)))
        case let .refined(session, text):
            guard case let .refining(current, delivery, _) = state, current == session else { break }
            deliver(session, text, delivery, &out)
        case let .refineFailed(session):
            guard case let .refining(current, delivery, raw) = state, current == session else { break }
            deliver(session, raw, delivery, &out)
        case let .pasted(session):
            guard case let .pasting(current) = state, current == session else { break }
            finish(&out)
        }
        return out
    }

    /// The session in progress, if any.
    public var session: Session? {
        switch state {
        case .idle: nil
        case let .starting(session, _, _), let .recording(session, _), let .recognizing(session, _, _),
             let .refining(session, _, _), let .pasting(session): session
        }
    }

    // MARK: - Inputs

    private mutating func voice(_ signal: VoiceSignal, _ out: inout [Output]) {
        switch (state, signal) {
        case (.idle, .toggle):
            start(.tap, &out)
        case (.idle, .holdBegan):
            start(.hold, &out)

        case (.starting(_, .tap, _), .toggle):
            queue(.stop(.trigger))
        case let (.starting(_, .hold, _), .holdEnded(reason)):
            queue(.stop(reason == .released ? .trigger : .holdLost))
        case (.starting, .cancel):
            queue(.cancel(.escape))

        case (.recording(_, .tap), .toggle):
            stop(.trigger, &out)
        case let (.recording(_, .hold), .holdEnded(reason)):
            stop(reason == .released ? .trigger : .holdLost, &out)
        case (.recording, .cancel):
            cancel(.escape, &out)

        case (.recognizing, .toggle), (.recognizing, .holdBegan):
            out.append(.phase(.stillRecognizing))
        case (.recognizing, .cancel):
            cancel(.escape, &out)

        case let (.refining(session, delivery, raw), .cancel):
            // Esc gives up on the language model, never on the dictation.
            out.append(.stopRefining(session))
            deliver(session, raw, delivery, &out)

        default:
            // A tap during a hold session and the like, and anything while
            // pasting: the table has nothing for them.
            break
        }
    }

    private mutating func start(_ trigger: Trigger, _ out: inout [Output]) {
        guard !secureInput else { return }
        lastSession += 1
        refines = false
        state = .starting(lastSession, trigger, pending: nil)
        escapeTaken = true
        out += [.sessionActive(true), .takesEscape(true), .phase(.starting), .startCapture(lastSession)]
        if trigger == .hold { out.append(.watchHold(true)) }
    }

    private mutating func captureStarted(_ session: Session, _ out: inout [Output]) {
        guard case let .starting(current, trigger, pending) = state, current == session else { return }
        state = .recording(session, trigger)
        switch pending {
        case nil:
            out += [.sound(.start), .phase(.recording)]
        case let .stop(reason):
            stop(reason, &out)
        case let .cancel(reason):
            cancel(reason, &out)
        }
    }

    /// A stop or a cancel while the microphone starts runs once it started:
    /// the start cannot be taken back half way. A cancel wins over a stop.
    private mutating func queue(_ pending: Pending) {
        guard case let .starting(session, trigger, current) = state else { return }
        if case .cancel = current { return }
        if case .stop = current, case .stop = pending { return }
        state = .starting(session, trigger, pending: pending)
    }

    private mutating func stopAny(_ reason: StopReason, _ out: inout [Output]) {
        switch state {
        case .starting:
            queue(.stop(reason))
        case .recording:
            stop(reason, &out)
        case .idle, .recognizing, .refining, .pasting:
            break
        }
    }

    private mutating func cancelAny(_ reason: CancelReason, _ out: inout [Output]) {
        switch state {
        case .starting:
            queue(.cancel(reason))
        case .recording:
            cancel(reason, &out)
        case .idle, .recognizing, .refining, .pasting:
            // Asleep, recognition, the language model and the paste wait:
            // the paste checks its target.
            break
        }
    }

    private mutating func accessibilityLost(_ out: inout [Output]) {
        switch state {
        case let .recognizing(session, _, refines):
            state = .recognizing(session, .keep, refines: refines)
        case let .refining(session, _, raw):
            state = .refining(session, .keep, raw: raw)
        case let .starting(session, trigger, .stop):
            // Whatever stop waits, the text must not be pasted now.
            state = .starting(session, trigger, pending: .stop(.accessibilityLost))
        default:
            stopAny(.accessibilityLost, &out)
        }
    }

    // MARK: - Transitions

    private mutating func stop(_ reason: StopReason, _ out: inout [Output]) {
        guard case let .recording(session, trigger) = state else { return }
        let delivery: Delivery = reason == .accessibilityLost ? .keep : .paste
        state = .recognizing(session, delivery, refines: refines)
        out += [.stopCapture(session), .sound(.stop)]
        if trigger == .hold { out.append(.watchHold(false)) }
        out += [.phase(.recognizing), .recognize(session, delivery)]
    }

    private mutating func cancel(_ reason: CancelReason, _ out: inout [Output]) {
        guard let session else { return }
        var trigger: Trigger?
        if case let .recording(_, current) = state { trigger = current }
        out.append(.discard(session))
        finish(trigger: trigger, &out)
        out.append(.phase(.cancelled))
    }

    /// The text goes in, or is only kept without Accessibility.
    private mutating func deliver(_ session: Session, _ text: String, _ delivery: Delivery, _ out: inout [Output]) {
        if delivery == .paste {
            state = .pasting(session)
            releaseEscape(&out)
            out += [.phase(.pasting), .paste(session, text)]
        } else {
            finish(&out)
            out.append(.keep(session, text))
        }
    }

    private mutating func releaseEscape(_ out: inout [Output]) {
        guard escapeTaken else { return }
        escapeTaken = false
        out.append(.takesEscape(false))
    }

    private mutating func finish(trigger: Trigger? = nil, _ out: inout [Output]) {
        state = .idle
        if trigger == .hold { out.append(.watchHold(false)) }
        releaseEscape(&out)
        out.append(.sessionActive(false))
    }
}
