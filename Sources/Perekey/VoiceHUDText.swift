// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import PerekeyVoice

/// The words of the dictation HUD (table Voice), for the screen and for
/// VoiceOver. `DictationHUDPresentation` decides what the HUD says; these say it.
extension DictationHUDPresentation.Message {
    var text: String {
        switch self {
        case .starting: voiceString("Starting the microphone…")
        case .recording: voiceString("Recording")
        case .preparingModel: voiceString("Getting the model ready…")
        case .recognizing: voiceString("Recognizing…")
        case .stillRecognizing: voiceString("Still recognizing…")
        case .refining: voiceString("Improving…")
        case .pasting: voiceString("Pasting…")
        case .pasted: voiceString("Done")
        case .copied: voiceString("Copied")
        case .pastedAsSaid(.escape), .pastedAsSaid(.answered): voiceString("Pasted as said")
        case .pastedAsSaid(.timedOut): voiceString("The language model took too long: pasted as said")
        case .pastedAsSaid(.failed): voiceString("The language model failed: pasted as said")
        case let .pastedAsSaid(.needsConsent(host)): voiceString("Allow sending to \(host) first: pasted as said")
        case let .pastedAsSaid(.needsKey(endpoint)): voiceString("No \(endpoint) key: pasted as said")
        case .pastedAsSaid(.cloudOff): voiceString("The cloud is off by your administrator: pasted as said")
        case .pastedAsSaid(.modesLocked): voiceString("Modes are from a newer Perekey: pasted as said")
        case .notPasted: voiceString("Text not pasted")
        case .secureField: voiceString("The cursor is in a password field")
        case let .secureInput(owner?): voiceString("Input is protected in \(owner)")
        case .secureInput(nil): voiceString("Input is protected in another app")
        case .noAccessibility: voiceString("Perekey lost its Accessibility access")
        case .timedOut: voiceString("The app did not answer")
        case .nothingHeard: voiceString("Nothing heard")
        case .cancelled: voiceString("Cancelled")
        case .microphoneDenied: voiceString("No access to the microphone")
        case .noMicrophone: voiceString("No microphone found")
        case .microphoneFailed: voiceString("Microphone error")
        case .modelFailed: voiceString("The speech model is not ready")
        case .cloudSpeechFailed: voiceString("The cloud did not answer")
        case .pastedAsSaid(.cloudSpeechFailed): voiceString("The cloud did not answer: recognized on this Mac")
        case .recognitionFailed: voiceString("Could not recognize the speech")
        }
    }

    /// What the HUD shows is a problem the person can still act on.
    var isProblem: Bool {
        switch self {
        case .notPasted, .secureField, .secureInput, .noAccessibility, .timedOut, .nothingHeard,
             .microphoneDenied, .noMicrophone, .microphoneFailed, .modelFailed, .recognitionFailed,
             .cloudSpeechFailed: true
        case .starting, .recording, .preparingModel, .recognizing, .stillRecognizing, .refining, .pasting, .pasted,
             .copied, .cancelled: false
        case let .pastedAsSaid(fallback): fallback != .escape
        }
    }

    /// The glyph before the text when there is no meter.
    var symbol: String? {
        switch self {
        case .pasted, .copied, .pastedAsSaid(.escape): "checkmark.circle.fill"
        case .pastedAsSaid: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .nothingHeard: "mic.slash"
        case .microphoneDenied, .noMicrophone, .microphoneFailed: "mic.slash.fill"
        case .secureField, .secureInput: "lock.fill"
        case .notPasted, .noAccessibility, .timedOut, .modelFailed, .recognitionFailed, .cloudSpeechFailed:
            "exclamationmark.triangle.fill"
        case .starting, .recording, .preparingModel, .recognizing, .stillRecognizing, .refining, .pasting: nil
        }
    }
}

extension DictationHUDPresentation.Button {
    var title: String {
        switch self {
        case .cancel: voiceString("Cancel")
        case .pasteAsSaid: voiceString("Skip improving")
        case .paste: voiceString("Paste")
        case .copy: voiceString("Copy")
        case .openMicrophoneSettings, .openAccessibilitySettings, .openVoiceSettings: voiceString("Open Settings")
        case .retry: voiceString("Retry")
        }
    }

    /// The Esc keycap beside the label, where the key does the same.
    var keycap: String? { self == .cancel || self == .pasteAsSaid ? "esc" : nil }

    var accessibilityLabel: String {
        switch self {
        case .cancel: voiceString("Cancel dictation")
        case .pasteAsSaid: voiceString("Paste without improving")
        case .paste: voiceString("Paste the text")
        case .copy: voiceString("Copy the text")
        case .openMicrophoneSettings: voiceString("Open the microphone settings")
        case .openAccessibilitySettings: voiceString("Open the Accessibility settings")
        case .openVoiceSettings: voiceString("Open the voice settings")
        case .retry: voiceString("Send the dictation to the cloud again")
        }
    }
}

extension DictationHUDPresentation {
    /// What VoiceOver says when the message changes: the message, and the
    /// buttons when there are some, so that the person knows what to do.
    var spokenText: String {
        message.text
    }
}
#endif
