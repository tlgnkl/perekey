// SPDX-License-Identifier: GPL-3.0-or-later

/// What dictation reads from the user's settings, with the plan's defaults:
/// Parakeet TDT v3, the system microphone, the layout switch and the sounds
/// on, a stop after 30 s of silence, the model unloaded after 60 minutes
/// without dictation.
public struct DictationPreferences: Hashable, Sendable {
    /// Parakeet TDT v3: ru, en, uk, and English words kept in Latin letters
    /// within Russian phrases (stage 0).
    public static let defaultModel = "parakeet-tdt-v3"

    /// Nil follows the system microphone.
    public var microphoneUID: String?
    /// A recognizer of `ModelCatalog`.
    public var modelID: String
    /// After a paste, select the layout of the phrase's main language.
    public var switchesLayout: Bool
    /// The system sounds at the start and the end of a recording.
    public var playsSounds: Bool
    /// A recording stops after this long without speech; nil never.
    public var silenceStop: Duration?
    /// The model leaves memory after this long without dictation; nil never.
    public var unloadAfter: Duration?

    public init(microphoneUID: String? = nil, modelID: String = DictationPreferences.defaultModel,
                switchesLayout: Bool = true, playsSounds: Bool = true, silenceStop: Duration? = .seconds(30),
                unloadAfter: Duration? = .seconds(60 * 60))
    {
        self.microphoneUID = microphoneUID
        self.modelID = modelID
        self.switchesLayout = switchesLayout
        self.playsSounds = playsSounds
        self.silenceStop = silenceStop
        self.unloadAfter = unloadAfter
    }
}
