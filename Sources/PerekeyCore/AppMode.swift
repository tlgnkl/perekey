// SPDX-License-Identifier: GPL-3.0-or-later

/// What Perekey does in one app.
public enum AppMode: String, CaseIterable, Hashable, Sendable, Codable {
    /// Fixes words by itself and on command.
    case auto
    /// Fixes only on the user's command (shortcuts work, autoswitch stays quiet).
    case manualOnly
    /// Does nothing: no fixes, no shortcuts.
    case off
}

/// The user's rule for one app, keyed by bundle ID in `AppSettings.apps`.
public struct AppRule: Hashable, Sendable, Codable {
    public var mode: AppMode
    /// The layout to select whenever the app comes to the front.
    public var defaultLayout: LayoutID?
    /// Without a default layout: return to the layout the user left the app with.
    public var rememberLastLayout: Bool

    public init(mode: AppMode = .auto, defaultLayout: LayoutID? = nil, rememberLastLayout: Bool = false) {
        self.mode = mode
        self.defaultLayout = defaultLayout
        self.rememberLastLayout = rememberLastLayout
    }

    private enum CodingKeys: String, CodingKey {
        case mode, defaultLayout, rememberLastLayout
    }

    /// Tolerant: a missing or unknown field falls back to its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(AppMode.self, forKey: .mode)) ?? .auto
        defaultLayout = (try? container.decodeIfPresent(LayoutID.self, forKey: .defaultLayout)) ?? nil
        rememberLastLayout = (try? container.decodeIfPresent(Bool.self, forKey: .rememberLastLayout)) ?? false
    }
}

/// The built-in defaults and the resolver of an app's mode.
public enum AppModes {
    /// Terminals and code editors: `.manualOnly`.
    public static let manualOnlyBundleIDs: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.apple.dt.Xcode",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.barebones.bbedit",
    ]

    /// Every JetBrains IDE.
    public static let manualOnlyPrefixes: [String] = ["com.jetbrains."]

    /// The mode a built-in default gives, or `nil` when there is none.
    public static func builtInMode(bundleID: String) -> AppMode? {
        if manualOnlyBundleIDs.contains(bundleID) { return .manualOnly }
        if manualOnlyPrefixes.contains(where: bundleID.hasPrefix) { return .manualOnly }
        return nil
    }

    /// Whether the app's `LSApplicationCategoryType` marks a game.
    public static func isGame(category: String?) -> Bool {
        category?.lowercased().contains("games") ?? false
    }

    /// The mode in force: the user's rule, else the built-in default, else
    /// `.off` for a game, else `.auto`.
    public static func effectiveMode(bundleID: String, isGame: Bool, rules: [String: AppRule]) -> AppMode {
        if let rule = rules[bundleID] { return rule.mode }
        if let builtIn = builtInMode(bundleID: bundleID) { return builtIn }
        return isGame ? .off : .auto
    }
}
