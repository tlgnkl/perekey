// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// Picks the mode of a dictation: a mode pinned in the menu, else the one
/// bound to the site in front, else to the app, else the default.
public enum ModeResolver {
    public enum Reason: Hashable, Sendable {
        case pinned
        case site(String)
        case app(String)
        case fallback
    }

    /// - Parameters:
    ///   - bundleID: the app in front, nil when there is none.
    ///   - host: the normalized host of the page in front, for a browser only.
    public static func resolve(bundleID: String?, host: String?, in set: VoiceModeSet)
        -> (mode: VoiceMode, reason: Reason)?
    {
        if let pinned = set.mode(set.pinnedModeID) { return (pinned, .pinned) }
        if let host {
            // The most specific host wins, whichever mode has it.
            for candidate in SiteHost.candidates(for: host) {
                if let mode = set.modes.first(where: { $0.bindings.contains(.site(candidate)) }) {
                    return (mode, .site(candidate))
                }
            }
        }
        if let bundleID {
            // An exact ID wins over a prefix.
            if let mode = set.modes.first(where: { $0.bindings.contains(.app(bundleID)) }) {
                return (mode, .app(bundleID))
            }
            if let mode = set.modes.first(where: { $0.bindings.contains { $0.matches(bundleID: bundleID) } }) {
                return (mode, .app(bundleID))
            }
        }
        return set.defaultMode.map { ($0, .fallback) }
    }
}

/// Terminals: a line break there runs what was typed, so dictated text goes
/// in on one line and Enter is never pressed, whatever the mode.
public enum Terminals {
    public static let bundleIDs = Set(AppModes.terminalBundleIDs)

    public static func contains(_ bundleID: String?) -> Bool {
        bundleID.map(bundleIDs.contains) ?? false
    }

    /// Line breaks and the spaces around them become one space, a tab a
    /// space; every other control character goes: Ctrl-O or an escape
    /// sequence would act in the terminal.
    public static func singleLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                scalars.append(" ")
            } else if scalar == "\n" || scalar == "\r" || scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        var result = ""
        var pendingBreak = false
        for character in String(scalars) {
            if character.isNewline {
                pendingBreak = true
                while result.last == " " || result.last == "\t" { result.removeLast() }
                continue
            }
            if pendingBreak {
                if character == " " || character == "\t" { continue }
                if !result.isEmpty { result.append(" ") }
                pendingBreak = false
            }
            result.append(character)
        }
        return result
    }
}
