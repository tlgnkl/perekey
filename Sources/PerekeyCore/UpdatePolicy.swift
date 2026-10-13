// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Settings an organization forces with a configuration profile (MDM), in the
/// `app.perekey.Perekey` preference domain. Keys are listed in
/// docs/managed-preferences.md. Only forced values count: a value the user
/// wrote with `defaults write` is not "managed".
public struct ManagedSettings: Hashable, Sendable {
    public static let domain = "app.perekey.Perekey"

    public enum Key {
        /// Bool. `true`: no update checks, not even by hand. Perekey makes no network requests.
        public static let updatesDisabled = "UpdatesDisabled"
        /// Bool. `true`: voice input is off and hidden.
        public static let voiceDisabled = "VoiceDisabled"
        /// Bool. `true`: no "Download" for speech models; they load only from
        /// the folder an administrator fills, `VoiceModels/<id>/` in
        /// `/Library/Application Support/Perekey`, checked against the same SHA-256.
        public static let voiceModelDownloadsDisabled = "VoiceModelDownloadsDisabled"
        /// Bool. `true`: no cloud speech recognition and no cloud language models.
        public static let voiceCloudDisabled = "VoiceCloudDisabled"
    }

    public var updatesDisabled: Bool
    public var voiceDisabled: Bool
    public var voiceModelDownloadsDisabled: Bool
    public var voiceCloudDisabled: Bool

    public init(updatesDisabled: Bool = false, voiceDisabled: Bool = false, voiceModelDownloadsDisabled: Bool = false,
                voiceCloudDisabled: Bool = false)
    {
        self.updatesDisabled = updatesDisabled
        self.voiceDisabled = voiceDisabled
        self.voiceModelDownloadsDisabled = voiceModelDownloadsDisabled
        self.voiceCloudDisabled = voiceCloudDisabled
    }

    /// Reads the keys through `forced`, which returns a value only when a profile forces the key.
    public init(forced: (String) -> Any?) {
        updatesDisabled = (forced(Key.updatesDisabled) as? Bool) ?? false
        voiceDisabled = (forced(Key.voiceDisabled) as? Bool) ?? false
        voiceModelDownloadsDisabled = (forced(Key.voiceModelDownloadsDisabled) as? Bool) ?? false
        voiceCloudDisabled = (forced(Key.voiceCloudDisabled) as? Bool) ?? false
    }

    /// True when a profile forces any key, updates or voice. A pane with a
    /// "Managed by your organization" note asks about its own key instead.
    public var forcesAnyKey: Bool {
        updatesDisabled || voiceDisabled || voiceModelDownloadsDisabled || voiceCloudDisabled
    }
}

/// What the updater may do: the result of the build, the profile and the user's switch.
public struct UpdatePolicy: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// A profile forbids updates. The updater is never created.
        case managedOff
        /// The build has no feed address or no valid public key (development builds).
        /// The updater is never created.
        case notConfigured
        /// Sparkle checks on its own schedule.
        case automatic
        /// Sparkle checks only when the user asks.
        case manual
    }

    public let state: State

    public init(configured: Bool, managed: ManagedSettings, checkAutomatically: Bool) {
        if managed.updatesDisabled {
            state = .managedOff
        } else if !configured {
            state = .notConfigured
        } else {
            state = checkAutomatically ? .automatic : .manual
        }
    }

    /// Start Sparkle at launch. With automatic checks off it stays stopped
    /// until the user asks for a check, so it cannot reach the network by itself.
    public var startsAtLaunch: Bool { state == .automatic }

    /// "Check Now" and "Check for Updates…" work.
    public var canCheckNow: Bool { state == .automatic || state == .manual }

    /// The switch "Check for updates automatically" cannot change.
    public var isLocked: Bool { state == .managedOff }
}

/// The update settings Info.plist carries.
public enum UpdateFeed {
    /// The appcast address; `SUFeedURL` in Info.plist. README names it in "Network".
    public static let url = "https://tlgnkl.github.io/perekey/appcast.xml"

    /// True when Info.plist has an https feed and an EdDSA public key that decodes
    /// to 32 bytes. The placeholder of development builds fails this check.
    public static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, feedURL.hasPrefix("https://"), let publicKey,
              let key = Data(base64Encoded: publicKey) else { return false }
        return key.count == 32
    }
}
