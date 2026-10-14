// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the dictation HUD says and offers for one `DictationHUDState`, as
/// values with no words in them: the app turns a `Message` and a `Button`
/// into the strings of the Voice table, the way it speaks them to VoiceOver.
public struct DictationHUDPresentation: Hashable, Sendable {
    public enum Message: Hashable, Sendable {
        /// Level and timer; the microphone is starting.
        case starting
        /// Level and timer; the person is speaking.
        case recording
        /// The speech model still loads: "Готовлю модель…".
        case preparingModel
        case recognizing
        case stillRecognizing
        /// The mode's language model edits the text: "Улучшаю".
        case refining
        case pasting
        case pasted
        /// The text went in as recognized: the mode's step was skipped, for
        /// this reason ("Вставлен исходный текст").
        case pastedAsSaid(ModeFallback)
        /// The text went to the pasteboard.
        case copied
        /// "Текст не вставлен".
        case notPasted
        /// "Курсор в поле пароля".
        case secureField
        /// "Ввод защищён в <программа>"; `owner` is nil when the app is unknown.
        case secureInput(owner: String?)
        /// Accessibility was revoked.
        case noAccessibility
        /// The app did not answer; the text may still arrive.
        case timedOut
        case nothingHeard
        case cancelled
        case microphoneDenied
        case noMicrophone
        case microphoneFailed
        /// The speech model is missing or did not load.
        case modelFailed
        /// The cloud did not answer and no model on this Mac could stand in.
        case cloudSpeechFailed
        case recognitionFailed
    }

    public enum Button: Hashable, Sendable {
        /// Esc: ends the dictation. It matters under Secure Input, where Esc
        /// does not reach Perekey.
        case cancel
        /// Esc while the language model works: paste the text as recognized.
        case pasteAsSaid
        /// Paste the last text where the caret is now.
        case paste
        /// Put the last text on the pasteboard.
        case copy
        /// Privacy → Microphone.
        case openMicrophoneSettings
        /// Privacy → Accessibility.
        case openAccessibilitySettings
        /// Settings → Voice, where the models are.
        case openVoiceSettings
        /// Send the kept audio to the cloud again.
        case retry
    }

    /// The level and the timer above the message.
    public struct Meter: Hashable, Sendable {
        /// 0...1.
        public var level: Float
        public var seconds: Double

        public init(level: Float, seconds: Double) {
            self.level = level
            self.seconds = seconds
        }

        /// "0:07", "12:03".
        public var timerText: String {
            let whole = max(0, Int(seconds))
            return "\(whole / 60):" + (whole % 60 < 10 ? "0" : "") + "\(whole % 60)"
        }
    }

    /// How long the HUD stays once the state is final; nil while the state lasts.
    public var message: Message
    public var buttons: [Button]
    public var meter: Meter?
    public var hidesAfter: TimeInterval?
    /// The audio or the text leaves the Mac: ☁ beside the mode.
    public var cloud = false
    /// The dictation's mode, while it records and while the language model works.
    public var modeName: String?
    /// The language model's server, while it works: "Ollama", "OpenAI".
    public var endpointName: String?

    public var isVisible: Bool { true }

    public init(message: Message, buttons: [Button] = [], meter: Meter? = nil, hidesAfter: TimeInterval? = nil) {
        self.message = message
        self.buttons = buttons
        self.meter = meter
        self.hidesAfter = hidesAfter
    }

    /// Seconds a final state stays on screen. Not-pasted stays longest: the
    /// buttons need time, and the pointer over the HUD holds it as well.
    public enum Lifetime {
        public static let confirmation: TimeInterval = 1.2
        public static let notice: TimeInterval = 2.2
        public static let error: TimeInterval = 8
        public static let notPasted: TimeInterval = 15
    }

    /// The HUD for `state`, nil for `.hidden`.
    public init?(_ state: DictationHUDState, hasText: Bool = true) {
        switch state {
        case .hidden:
            return nil
        case .starting:
            self.init(message: .starting, buttons: [.cancel], meter: Meter(level: 0, seconds: 0))
        case let .recording(recording):
            self.init(message: recording.preparingModel ? .preparingModel : .recording, buttons: [.cancel],
                      meter: Meter(level: min(1, max(0, recording.level)), seconds: recording.seconds))
            modeName = recording.mode
            cloud = recording.cloudHost != nil
        case let .refining(refining):
            self.init(message: .refining, buttons: [.pasteAsSaid])
            modeName = refining.mode
            endpointName = refining.endpoint
            cloud = refining.isCloud
        case let .recognizing(preparingModel):
            self.init(message: preparingModel ? .preparingModel : .recognizing, buttons: [.cancel])
        case .stillRecognizing:
            self.init(message: .stillRecognizing, buttons: [.cancel])
        case .pasting:
            self.init(message: .pasting)
        case .pasted:
            self.init(message: .pasted, hidesAfter: Lifetime.confirmation)
        case let .pastedFallback(fallback):
            // Esc asked for it: a confirmation. Anything else is news.
            self.init(message: .pastedAsSaid(fallback),
                      hidesAfter: fallback == .escape ? Lifetime.confirmation : Lifetime.notice)
        case .copied:
            self.init(message: .copied, hidesAfter: Lifetime.confirmation)
        case let .notPasted(reason):
            self.init(reason, hasText: hasText)
        case .nothingHeard:
            self.init(message: .nothingHeard, hidesAfter: Lifetime.notice)
        case .cancelled:
            self.init(message: .cancelled, hidesAfter: Lifetime.confirmation)
        case let .failed(failure):
            switch failure {
            case .microphoneDenied:
                self.init(message: .microphoneDenied, buttons: [.openMicrophoneSettings], hidesAfter: Lifetime.error)
            case .noMicrophone:
                self.init(message: .noMicrophone, hidesAfter: Lifetime.error)
            case .microphone:
                self.init(message: .microphoneFailed, hidesAfter: Lifetime.error)
            case .model:
                self.init(message: .modelFailed, buttons: [.openVoiceSettings], hidesAfter: Lifetime.error)
            case .cloudSpeech:
                self.init(message: .cloudSpeechFailed, buttons: [.retry], hidesAfter: Lifetime.notPasted)
            case .recognition:
                self.init(message: .recognitionFailed, hidesAfter: Lifetime.error)
            }
        }
    }

    /// "Текст не вставлен · Вставить · Скопировать". "Вставить" only where
    /// `NotPastedReason.offersPaste`; no buttons for a text that is gone.
    private init(_ reason: NotPastedReason, hasText: Bool) {
        let message: Message = switch reason {
        case .targetChanged, .failed: .notPasted
        case .secureField: .secureField
        case let .secureInput(owner): .secureInput(owner: owner)
        case .noAccessibility: .noAccessibility
        case .timedOut: .timedOut
        }
        var buttons: [Button] = []
        // A text meant for a password or a protected field never goes to the
        // pasteboard or into another field from here.
        let isPrivate: Bool = switch reason {
        case .secureField, .secureInput: true
        default: false
        }
        if hasText, !isPrivate {
            if reason.offersPaste { buttons.append(.paste) }
            buttons.append(.copy)
        }
        if reason == .noAccessibility { buttons.append(.openAccessibilitySettings) }
        self.init(message: message, buttons: buttons, hidesAfter: Lifetime.notPasted)
    }

    /// VoiceOver says something when the message changes, not at every tick
    /// of the timer and the level.
    public static func announces(_ new: DictationHUDPresentation?, after old: DictationHUDPresentation?) -> Bool {
        guard let new else { return false }
        return new.message != old?.message
    }
}
