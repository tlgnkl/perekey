// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// What `VoiceHTTP` may reach, as a function of the user's switch, the voice
/// file, this Mac and the organization's profile. The app applies it on every
/// change of any of them, so that the network is open only while voice is on:
/// with voice off, a settings file of a newer version, an unsupported Mac, or
/// a profile that forbids voice or downloads, no model request is ever made.
/// Whenever the answer is empty, running downloads stop.
public enum VoiceNetworkPolicy {
    /// - Parameter newerSchemaVersion: the version of a voice file newer than
    ///   this Perekey, if it is: its switch cannot be trusted, so voice stays off.
    public static func allowed(isEnabled: Bool, newerSchemaVersion: Int? = nil, isSupported: Bool = true,
                               managed: ManagedSettings) -> Set<VoiceHTTP.Purpose>
    {
        guard isEnabled, newerSchemaVersion == nil, isSupported,
              !managed.voiceDisabled, !managed.voiceModelDownloadsDisabled
        else { return [] }
        return [.modelDownload]
    }

    /// Opens or closes `http` for the current settings.
    public static func apply(isEnabled: Bool, newerSchemaVersion: Int? = nil, isSupported: Bool = true,
                             managed: ManagedSettings, to http: VoiceHTTP = .shared)
    {
        http.allowed = allowed(isEnabled: isEnabled, newerSchemaVersion: newerSchemaVersion,
                               isSupported: isSupported, managed: managed)
    }
}
