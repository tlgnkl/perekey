// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// What dictation reads from the user's settings, with the plan's defaults:
/// Parakeet TDT v3, the system microphone, the layout switch and the sounds
/// on, a stop after 30 s of silence, the model unloaded after 60 minutes
/// without dictation.
public struct DictationPreferences: Hashable, Sendable {
    /// Parakeet TDT v3, as in the settings.
    public static let defaultModel = VoiceSettings.defaultModel

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
    /// «Язык диктовки: как в программе»: a dictation gets the language hint
    /// of `DictationLanguageHint` when there is one. Off, the model finds
    /// the language, as before.
    ///
    /// With `recognizesWhileSpeaking` the hint is read once, at the first cut,
    /// and holds for all the pieces and for the fallback to the whole
    /// recording: the pieces of one dictation must not go in different
    /// languages. This departs from a dictation recognized whole, where the
    /// app and the layout are read after the stop; a switch of either during
    /// the speech is not seen by the pieces.
    public var languageFromApp: Bool
    /// «Распознавать во время речи»: a dictation on this Mac is recognized in
    /// pieces cut at its pauses while it is spoken (`SpeechSegmenter`). Off,
    /// the whole recording after the stop, as before.
    public var recognizesWhileSpeaking: Bool

    public init(microphoneUID: String? = nil, modelID: String = DictationPreferences.defaultModel,
                switchesLayout: Bool = true, playsSounds: Bool = true, silenceStop: Duration? = .seconds(30),
                unloadAfter: Duration? = .seconds(60 * 60), languageFromApp: Bool = false,
                recognizesWhileSpeaking: Bool = false)
    {
        self.microphoneUID = microphoneUID
        self.modelID = modelID
        self.switchesLayout = switchesLayout
        self.playsSounds = playsSounds
        self.silenceStop = silenceStop
        self.unloadAfter = unloadAfter
        self.languageFromApp = languageFromApp
        self.recognizesWhileSpeaking = recognizesWhileSpeaking
    }
}

extension DictationPreferences {
    /// What dictation reads of the user's settings (voice.json).
    public init(_ settings: VoiceSettings) {
        self.init(microphoneUID: settings.microphoneUID, modelID: settings.model,
                  switchesLayout: settings.switchesLayout, playsSounds: settings.playsSounds,
                  silenceStop: settings.autoStop.seconds.map { .seconds($0) },
                  unloadAfter: settings.unload.seconds.map { .seconds($0) },
                  languageFromApp: settings.dictationLanguage == .app,
                  recognizesWhileSpeaking: settings.recognizesWhileSpeaking)
    }
}
