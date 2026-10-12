// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

public extension SystemShortcuts {
    /// The shortcuts as macOS has them now. Synchronizes first: the user may
    /// have changed them in System Settings while Perekey was running.
    static func current() -> SystemShortcuts {
        let hotkeysDomain = "com.apple.symbolichotkeys" as CFString
        let toolboxDomain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(hotkeysDomain)
        CFPreferencesAppSynchronize(toolboxDomain)
        let stored = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, hotkeysDomain) as? [String: Any]
        var entries: [Int: Entry] = [:]
        for id in [ID.previousInputSource, ID.nextInputSource, ID.spotlight] {
            guard let entry = stored?[String(id)] as? [String: Any] else { continue }
            let value = entry["value"] as? [String: Any]
            let parameters = (value?["parameters"] as? [NSNumber])?.map(\.intValue) ?? []
            entries[id] = Entry(enabled: (entry["enabled"] as? NSNumber)?.boolValue ?? false, parameters: parameters)
        }
        let fnUsage = (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, toolboxDomain) as? NSNumber)?.intValue
        return SystemShortcuts(symbolicHotKeys: entries, fnUsageType: fnUsage)
    }
}
