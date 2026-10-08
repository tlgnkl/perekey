// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A command from outside the app: a `perekey://` link or an AppleScript.
///
/// Any web page can open a link, so only harmless actions exist here: pause,
/// resume, autoswitch and the mode of the app in front. No word lists, no import.
/// Anything not exactly in the grammar parses to `nil` and does nothing.
///
///     perekey://pause?minutes=30      minutes 1...1440, default 60
///     perekey://resume
///     perekey://autoswitch?on=0|1    no argument toggles
///     perekey://mode?value=auto|manual|off
public enum ControlCommand: Equatable, Sendable {
    case pause(minutes: Int)
    case resume
    /// `nil` toggles.
    case autoswitch(Bool?)
    case mode(AppMode)

    public static let scheme = "perekey"
    public static let defaultPauseMinutes = 60
    public static let pauseMinutesRange = 1...1440

    /// The command of a URL, or `nil` for anything that is not exactly one.
    public static func parse(_ url: URL) -> ControlCommand? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host?.lowercased()
        else { return nil }
        guard let arguments = arguments(of: parts) else { return nil }
        switch host {
        case "pause":
            guard arguments.keys.allSatisfy({ $0 == "minutes" }) else { return nil }
            guard let text = arguments["minutes"] else { return .pause(minutes: defaultPauseMinutes) }
            guard let minutes = integer(text), pauseMinutesRange.contains(minutes) else { return nil }
            return .pause(minutes: minutes)
        case "resume":
            return arguments.isEmpty ? .resume : nil
        case "autoswitch":
            guard arguments.keys.allSatisfy({ $0 == "on" }) else { return nil }
            switch arguments["on"] {
            case nil: return .autoswitch(nil)
            case "1": return .autoswitch(true)
            case "0": return .autoswitch(false)
            default: return nil
            }
        case "mode":
            guard arguments.keys.allSatisfy({ $0 == "value" }) else { return nil }
            switch arguments["value"] {
            case "auto": return .mode(.auto)
            case "manual": return .mode(.manualOnly)
            case "off": return .mode(.off)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The query as a dictionary; `nil` when a name repeats or has no value.
    private static func arguments(of parts: URLComponents) -> [String: String]? {
        var result: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard let value = item.value, result.updateValue(value, forKey: item.name) == nil else { return nil }
        }
        return result
    }

    /// ASCII digits only: no sign, no spaces, no `1e3`, no Unicode digits.
    private static func integer(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 6, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }
}
