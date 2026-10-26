// SPDX-License-Identifier: GPL-3.0-or-later

/// What the menu bar item looks like (Settings → General, «Menu bar»).
public enum MenuBarIconStyle: String, CaseIterable, Hashable, Sendable, Codable {
    /// The live capsule with the layout code.
    case capsule
    /// The layout code as plain template letters, like the system's own icons.
    case letters
    /// The icon the system shows for the layout in its input menu.
    case system
    /// One Perekey mark, no language.
    case mark

    /// Whether the item tells the layout.
    public var showsLanguage: Bool { self != .mark }
}

/// When the menu bar item is on screen.
public enum MenuBarVisibility: String, CaseIterable, Hashable, Sendable, Codable {
    case always
    /// Only while Perekey has something to say: a pause, automatic switching
    /// off, a call being recorded, or no access.
    case whenNeeded
    case never
}

/// What the menu bar item has to say right now.
public struct MenuBarSituation: Hashable, Sendable {
    public var paused: Bool
    public var autoswitchOff: Bool
    public var recordingCall: Bool
    /// Perekey has no Accessibility access: it does nothing, and says so.
    public var accessMissing: Bool

    public init(paused: Bool = false, autoswitchOff: Bool = false, recordingCall: Bool = false,
                accessMissing: Bool = false) {
        self.paused = paused
        self.autoswitchOff = autoswitchOff
        self.recordingCall = recordingCall
        self.accessMissing = accessMissing
    }

    public var hasNews: Bool { paused || autoswitchOff || recordingCall || accessMissing }
}

/// A note under the menu bar settings about the system's input menu.
public enum MenuBarNotice: Hashable, Sendable {
    /// The system menu and Perekey both show the language.
    case shownTwice
    /// Neither shows the language.
    case notShown
}

public enum MenuBarPolicy {
    /// Whether the item is on screen.
    public static func isVisible(_ visibility: MenuBarVisibility, _ situation: MenuBarSituation) -> Bool {
        // Without access the item is the way to the fix: no setting hides it.
        if situation.accessMissing { return true }
        switch visibility {
        case .always: return true
        case .whenNeeded: return situation.hasNews
        case .never: return false
        }
    }

    /// Whether Perekey shows the language at all: with this look, on every screen of the day.
    public static func showsLanguage(style: MenuBarIconStyle, visibility: MenuBarVisibility) -> Bool {
        style.showsLanguage && visibility == .always
    }

    /// Whether to say where call recording and file transcription are with the item
    /// not always on screen: voice is on and the item may be hidden.
    public static func showsVoiceEntriesNote(voiceIsOn: Bool, visibility: MenuBarVisibility) -> Bool {
        voiceIsOn && visibility != .always
    }

    /// The note to show, given whether the system's input menu is visible
    /// (`nil`: unknown, then no note).
    public static func notice(style: MenuBarIconStyle, visibility: MenuBarVisibility,
                              systemMenuVisible: Bool?) -> MenuBarNotice?
    {
        guard let systemMenuVisible else { return nil }
        let ours = showsLanguage(style: style, visibility: visibility)
        if systemMenuVisible && ours { return .shownTwice }
        if !systemMenuVisible && !ours { return .notShown }
        return nil
    }
}
