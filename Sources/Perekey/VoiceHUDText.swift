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
        case .pasting: voiceString("Pasting…")
        case .pasted: voiceString("Done")
        case .copied: voiceString("Copied")
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
        case .recognitionFailed: voiceString("Could not recognize the speech")
        }
    }

    /// What the HUD shows is a problem the person can still act on.
    var isProblem: Bool {
        switch self {
        case .notPasted, .secureField, .secureInput, .noAccessibility, .timedOut, .nothingHeard,
             .microphoneDenied, .noMicrophone, .microphoneFailed, .modelFailed, .recognitionFailed: true
        case .starting, .recording, .preparingModel, .recognizing, .stillRecognizing, .pasting, .pasted, .copied, .cancelled: false
        }
    }

    /// The glyph before the text when there is no meter.
    var symbol: String? {
        switch self {
        case .pasted, .copied: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .nothingHeard: "mic.slash"
        case .microphoneDenied, .noMicrophone, .microphoneFailed: "mic.slash.fill"
        case .secureField, .secureInput: "lock.fill"
        case .notPasted, .noAccessibility, .timedOut, .modelFailed, .recognitionFailed: "exclamationmark.triangle.fill"
        case .starting, .recording, .preparingModel, .recognizing, .stillRecognizing, .pasting: nil
        }
    }
}

extension DictationHUDPresentation.Button {
    var title: String {
        switch self {
        case .cancel: voiceString("Cancel")
        case .paste: voiceString("Paste")
        case .copy: voiceString("Copy")
        case .openMicrophoneSettings, .openAccessibilitySettings, .openVoiceSettings: voiceString("Open Settings")
        }
    }

    /// The Esc keycap beside the label, where the key does the same.
    var keycap: String? { self == .cancel ? "esc" : nil }

    var accessibilityLabel: String {
        switch self {
        case .cancel: voiceString("Cancel dictation")
        case .paste: voiceString("Paste the text")
        case .copy: voiceString("Copy the text")
        case .openMicrophoneSettings: voiceString("Open the microphone settings")
        case .openAccessibilitySettings: voiceString("Open the Accessibility settings")
        case .openVoiceSettings: voiceString("Open the voice settings")
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
