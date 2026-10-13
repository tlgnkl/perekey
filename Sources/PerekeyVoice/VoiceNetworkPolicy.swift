// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyVoiceCore

/// What `VoiceHTTP` may reach, as a function of the user's switch, the voice
/// file, this Mac, the organization's profile and the modes. The app applies
/// it on every change of any of them, so that the network is open only while
/// voice is on: with voice off, a settings file of a newer version, an
/// unsupported Mac, or a profile that forbids voice, no request is ever
/// made. Whenever the answer is empty, running downloads stop.
///
/// Model downloads need no profile against them. Cloud speech may reach only
/// servers on this Mac and those the user agreed to send the audio to; a
/// language model, those the user agreed to send the text to
/// (`VoiceModeSet.reachableOrigins`). With `VoiceCloudDisabled`, only this Mac's.
public enum VoiceNetworkPolicy {
    /// - Parameter newerSchemaVersion: the version of a voice file newer than
    ///   this Perekey, if it is: its switch cannot be trusted, so voice stays off.
    public static func allowed(isEnabled: Bool, newerSchemaVersion: Int? = nil, isSupported: Bool = true,
                               managed: ManagedSettings, modes: VoiceModeSet? = nil) -> Set<VoiceHTTP.Purpose>
    {
        guard isOn(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion, isSupported: isSupported,
                   managed: managed)
        else { return [] }
        var purposes: Set<VoiceHTTP.Purpose> = []
        if !managed.voiceModelDownloadsDisabled { purposes.insert(.modelDownload) }
        let origins = origins(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion, isSupported: isSupported,
                              managed: managed, modes: modes)
        for (purpose, reachable) in origins where !reachable.isEmpty {
            purposes.insert(purpose)
        }
        return purposes
    }

    /// The origins cloud speech and language models may reach.
    public static func origins(isEnabled: Bool, newerSchemaVersion: Int? = nil, isSupported: Bool = true,
                               managed: ManagedSettings, modes: VoiceModeSet?) -> [VoiceHTTP.Purpose: Set<String>]
    {
        guard let modes, isOn(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion,
                              isSupported: isSupported, managed: managed)
        else { return [:] }
        let cloudDisabled = managed.voiceCloudDisabled
        return [
            .cloudSpeech: modes.reachableOrigins(sending: .audio, cloudDisabled: cloudDisabled),
            .cloudLanguageModel: modes.reachableOrigins(sending: .text, cloudDisabled: cloudDisabled),
        ]
    }

    /// Opens or closes `http` for the current settings.
    public static func apply(isEnabled: Bool, newerSchemaVersion: Int? = nil, isSupported: Bool = true,
                             managed: ManagedSettings, modes: VoiceModeSet? = nil, to http: VoiceHTTP = .shared)
    {
        http.allowedOrigins = origins(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion,
                                      isSupported: isSupported, managed: managed, modes: modes)
        http.allowed = allowed(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion,
                               isSupported: isSupported, managed: managed, modes: modes)
    }

    private static func isOn(isEnabled: Bool, newerSchemaVersion: Int?, isSupported: Bool,
                             managed: ManagedSettings) -> Bool
    {
        isEnabled && newerSchemaVersion == nil && isSupported && !managed.voiceDisabled
    }
}
