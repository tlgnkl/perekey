// SPDX-License-Identifier: GPL-3.0-or-later

/// How dictation puts its text into one app: «Вставка диктовки» in the Apps
/// pane, stored in `VoiceSettings.insertion`.
public enum DictationInsertion: String, Hashable, Sendable, CaseIterable, Codable {
    /// Typed in a terminal, unless the text has a line break (`canType`); pasted elsewhere.
    case automatic = "auto"
    /// The pasteboard and ⌘V.
    case paste
    /// Key events that carry the text, the pasteboard untouched.
    case typing

    /// Apps where `.automatic` types. A terminal wraps a paste in
    /// bracketed-paste markers, and an app inside it may fold a long paste
    /// into "[Pasted text #1]": typed text shows in full. Code editors are not
    /// here, though some have a terminal: the editor is what most dictation
    /// goes to.
    public static let terminalBundleIDs: [String] = AppModes.terminalBundleIDs + [
        "com.stablyai.orca", "org.tabby", "co.zeit.hyper",
    ]

    public static func isTerminal(bundleID: String?) -> Bool {
        bundleID.map(terminalBundleIDs.contains) ?? false
    }

    /// Whether `text` can go in as typed keys: no line break and no control
    /// character. Typed, a break would be Return, which sends the line in a
    /// terminal, and a tab or an escape would be that key.
    public static func canType(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
        }
    }

    /// Whether `text` is typed into the app `bundleID` with this choice. Text
    /// that cannot be typed (`canType`) is pasted even with `.typing`.
    public func types(_ text: String, bundleID: String?) -> Bool {
        switch self {
        case .automatic: Self.isTerminal(bundleID: bundleID) && Self.canType(text)
        case .paste: false
        case .typing: Self.canType(text)
        }
    }
}
