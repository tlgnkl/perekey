// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyVoiceCore

/// Where a dictation's audio comes from: `AudioCapture` in the app, a fake
/// in tests and in the probe.
public protocol DictationMicrophone: Sendable {
    /// Starts feeding `audio`; throws if the microphone does not start.
    func begin(_ audio: DictationAudio) async throws -> AudioSubscription
    /// After it returns, `audio` gets nothing more.
    func end(_ subscription: AudioSubscription) async
    /// The microphone by UID, nil for the system one. Called between sessions.
    func select(_ uid: String?) async
    /// Asks for the permission when the person was not asked yet, and
    /// returns once they answered. Called before `begin`.
    func requestAccess() async
}

extension DictationMicrophone {
    public func select(_: String?) async {}
    public func requestAccess() async {}
}

extension AudioCapture: DictationMicrophone {
    public func select(_ uid: String?) async {
        selectMicrophone(uid: uid)
    }

    public func requestAccess() async {
        guard MicrophoneAccess.status == .notDetermined else { return }
        _ = await MicrophoneAccess.request()
    }

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
    /// The caret is in a password field: not pasted, and the text stays out
    /// of the history.
    case secureField
    /// Another app holds Secure Input (its name if known): not pasted.
    case secureInput(owner: String?)
    /// The app did not answer the paste in time: the text may still arrive,
    /// so it is not offered for pasting again, only for copying.
    case timedOut
    /// Not pasted, for certain.
    case failed(String)
}

/// Pastes dictated text where the dictation started. `TextPaster` in the
/// app, through `TextPasterAdapter`: the one place that knows its API.
@MainActor
public protocol DictationPaster: AnyObject {
    /// There is something to paste into: an app in front. Checked, at
    /// once, before a dictation starts.
    var hasTarget: Bool { get }
    /// Where the caret is now: app, window, field. Taken when a dictation starts.
    func captureTarget() async -> (any Sendable)?
    func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult
    /// The text on the pasteboard, for a mode that only copies.
    func copy(_ text: String)
    /// Return after a paste, for "Paste and Enter": only if `target` is still in front.
    func pressReturn(in target: (any Sendable)?) async -> DictationPasteResult
    /// The few characters before the caret in the target field: "" for an
    /// empty field, nil when it cannot be read. For the text rules.
    func caretContext(into target: (any Sendable)?) async -> String?
    /// The program the target belongs to, for the history.
    func application(of target: (any Sendable)?) -> DictationApplication?
    /// Whether a text dictated into `target` is private: the field is a
    /// password field, or Secure Input is on now. Asked whatever the paste
    /// answered: the paste checks the field only after Accessibility, the
    /// modifiers and the target, and a refusal on the way says nothing about it.
    func privacy(of target: (any Sendable)?) -> DictationPrivacy
}

/// A program a dictation went into.
public struct DictationApplication: Hashable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

extension DictationPaster {
    public var hasTarget: Bool { true }

    public func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func pressReturn(in _: (any Sendable)?) async -> DictationPasteResult { .pasted }
    public func caretContext(into _: (any Sendable)?) async -> String? { nil }
    public func application(of _: (any Sendable)?) -> DictationApplication? { nil }
    public func privacy(of _: (any Sendable)?) -> DictationPrivacy { .normal }
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
