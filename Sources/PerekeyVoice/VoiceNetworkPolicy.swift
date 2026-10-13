// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// What `VoiceHTTP` may reach, as a function of the user's switch and the
/// organization's profile. The app applies it on every change of either, so
/// that the network is open only while voice is on: with voice off, or a
/// profile that forbids voice or downloads, no model request is ever made.
public enum VoiceNetworkPolicy {
    public static func allowed(isEnabled: Bool, managed: ManagedSettings) -> Set<VoiceHTTP.Purpose> {
        guard isEnabled, !managed.voiceDisabled, !managed.voiceModelDownloadsDisabled else { return [] }
        return [.modelDownload]
    }

    /// Opens or closes `http` for the current settings.
    public static func apply(isEnabled: Bool, managed: ManagedSettings, to http: VoiceHTTP = .shared) {
        http.allowed = allowed(isEnabled: isEnabled, managed: managed)
    }
}
