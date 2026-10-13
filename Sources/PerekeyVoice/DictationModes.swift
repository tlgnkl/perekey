// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore

/// Why a dictation skipped its mode's cloud or language model step. The text
/// went in as recognized, by the local model when the cloud one was skipped,
/// and the HUD says why.
public enum ModeFallback: Hashable, Sendable {
    /// Esc while the language model worked.
    case escape
    case timedOut
    case failed
    /// `OutputGuard`: the model answered the text instead of editing it.
    case answered
    /// The user has not agreed to send this mode's data to the host yet.
    case needsConsent(host: String)
    /// The endpoint needs a key and has none.
    case needsKey(endpoint: String)
    /// `VoiceCloudDisabled`.
    case cloudOff
    /// The cloud speech model did not answer; the model on this Mac heard it.
    case cloudSpeechFailed
    /// The modes file was written by a newer Perekey.
    case modesLocked
}

/// The mode of one dictation, resolved as it starts: what model hears it,
/// whether a language model edits it, and where the text goes.
public struct DictationPlan: Sendable {
    public var modeID: String
    public var modeName: String
    /// The speech model; nil takes the voice settings'.
    public var speechModel: String?
    /// The host the audio goes to, for a cloud speech model.
    public var speechHost: String?
    /// The language model step; nil when the mode has none or it is skipped.
    public var refine: Refine?
    public var output: ModeOutput
    /// Line breaks become spaces: a single-line mode, or a terminal in front.
    public var singleLine: Bool
    /// A step of the mode this dictation skips.
    public var fallback: ModeFallback?
    /// What the source needs again for the language model: the app's name,
    /// the host, the selected text.
    public var appName: String?
    public var host: String?
    public var selection: Task<String?, Never>?

    public struct Refine: Hashable, Sendable {
        public var endpointName: String
        public var isCloud: Bool
        /// The longest wait for the model; then the text goes in as recognized.
        public var timeout: Duration

        public init(endpointName: String, isCloud: Bool, timeout: Duration = .seconds(20)) {
            self.endpointName = endpointName
            self.isCloud = isCloud
            self.timeout = timeout
        }
    }

    public init(modeID: String, modeName: String, speechModel: String? = nil, speechHost: String? = nil,
                refine: Refine? = nil, output: ModeOutput = .paste, singleLine: Bool = false,
                fallback: ModeFallback? = nil, appName: String? = nil, host: String? = nil,
                selection: Task<String?, Never>? = nil)
    {
        self.modeID = modeID
        self.modeName = modeName
        self.speechModel = speechModel
        self.speechHost = speechHost
        self.refine = refine
        self.output = output
        self.singleLine = singleLine
        self.fallback = fallback
        self.appName = appName
        self.host = host
        self.selection = selection
    }
}

/// The modes as dictation sees them: `VoiceModes` in the app.
@MainActor
public protocol DictationModeSource: AnyObject, Sendable {
    /// The mode for the app and the site in front. Called as a session starts.
    func plan() -> DictationPlan
    /// The plan's language model on `text`; throws on any failure. Its
    /// answer still goes through `OutputGuard`.
    func refine(_ text: String, plan: DictationPlan) async throws -> String
    /// A session is over, its text pasted: a window asking for consent may
    /// take the focus now.
    func sessionEnded(_ plan: DictationPlan)
}
