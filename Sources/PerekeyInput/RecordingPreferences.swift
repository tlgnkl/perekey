// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation

/// What the typing recording keeps in the user defaults: the apps the user
/// added to the password managers. Not whether it is on: decision Р1 of the
/// plan says it is switched on by hand, so every launch starts with it off
/// (an older dev build kept the switch; this removes what it left).
public struct RecordingPreferences {
    /// The key an older build kept the switch in. Read by nobody; removed.
    static let staleOnKey = "sessionRecording"
    static let excludedKey = "sessionRecordingExcludedApps"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.staleOnKey)
        self.defaults = defaults
    }

    /// Apps the user added to `RecordingBuffer.passwordManagers`.
    public var ownExcluded: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.excludedKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: Self.excludedKey) }
    }
}
#endif
