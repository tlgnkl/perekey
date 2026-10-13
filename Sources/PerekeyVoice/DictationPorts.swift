// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore

/// Where a dictation's audio comes from: `AudioCapture` in the app, a fake
/// in tests and in the probe.
public protocol DictationMicrophone: Sendable {
    /// Starts feeding `audio`; throws if the microphone does not start.
    func begin(_ audio: DictationAudio) async throws -> AudioSubscription
    /// After it returns, `audio` gets nothing more.
    func end(_ subscription: AudioSubscription) async
}

extension AudioCapture: DictationMicrophone {
    public func begin(_ audio: DictationAudio) async throws -> AudioSubscription {
        try subscribe(audio)
    }

    public func end(_ subscription: AudioSubscription) async {
        unsubscribe(subscription)
    }
}

/// What came of a paste.
public enum DictationPasteResult: Hashable, Sendable {
    case pasted
    /// The app, window or field changed since the start: the text was not
    /// pasted and the pasteboard was left alone.
    case targetChanged
    /// A password field, or Secure Input on, right before ⌘V.
    case secureField
    case failed(String)
}

/// Pastes dictated text where the dictation started. `TextPaster` in the
/// app: the adapter that joins them is the one place that knows its API.
@MainActor
public protocol DictationPaster: AnyObject {
    /// Where the caret is now: app, window, field. Taken when a dictation starts.
    func captureTarget() async -> (any Sendable)?
    func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult
}

/// The Secure Input rules of a session: no start while it is on; a stop
/// when it comes on during a session; Esc through a hot key then, since
/// the event tap no longer sees keys. `DictationSecureInput` in the app.
@MainActor
public protocol DictationSecureInputRules: AnyObject {
    var allowsStart: Bool { get }
    func sessionBegan()
    func sessionEnded()
    var onStop: (@MainActor () -> Void)? { get set }
    var onEscape: (@MainActor () -> Void)? { get set }
}
