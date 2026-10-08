// SPDX-License-Identifier: GPL-3.0-or-later

/// An immutable snapshot of the settings the input logic needs.
///
/// The app owns the editable settings. It sends a fresh snapshot to the event
/// tap thread as a whole, so the tap never reads half-updated state.
public struct Settings: Hashable, Sendable, Codable {
    public var hotkeys: [HotkeyBinding]
    /// Automatic switching while typing. ⇧+⇧ toggles it.
    public var autoswitch: Bool
    /// How long user input is held back after a retype at most, in seconds,
    /// when the layout change notification does not arrive.
    public var fenceTimeout: Double
    /// How long user input is held at most while the retype waits to be
    /// posted (the layout is selected on the main thread first). The
    /// `fenceTimeout` counts from the posting, not from the shortcut.
    public var postTimeout: Double
    /// Words automatic switching never touches: the user's own and the learned
    /// ones, normalized like `WordRules.normalize` (trimmed, lowercased).
    /// A word matches in either layout reading.
    public var exceptions: Set<String>
    /// Words automatic switching switches to whatever the classifier's score,
    /// unless a guard keeps the word (`Classifier.Reason.isGuard`). Normalized
    /// like `exceptions`, none of them in it. A word typed in the other layout
    /// reads as one of these: switch; typed as one of these: keep.
    public var alwaysFix: Set<String>
    /// Whether undoing an automatic switch asks the app to learn the word
    /// (`Effect.learned`).
    public var learnFromUndos: Bool
    /// The stage 4 corrections: phrase retype, case, Caps Lock, abbreviations, "ё".
    public var corrections: TextCorrections
    /// Typo correction at the end of a word (`TypoCorrector`). Off until it
    /// meets the plan's metric (docs/classifier.md, «Опечатки»).
    public var typoCorrection: Bool

    public init(
        hotkeys: [HotkeyBinding] = HotkeyPreset.default.hotkeys,
        autoswitch: Bool = true,
        fenceTimeout: Double = 0.3,
        postTimeout: Double = 2,
        exceptions: Set<String> = [],
        alwaysFix: Set<String> = [],
        learnFromUndos: Bool = true,
        corrections: TextCorrections = TextCorrections(),
        typoCorrection: Bool = true
    ) {
        self.hotkeys = hotkeys
        self.autoswitch = autoswitch
        self.fenceTimeout = fenceTimeout
        self.postTimeout = postTimeout
        self.exceptions = exceptions
        self.alwaysFix = alwaysFix
        self.learnFromUndos = learnFromUndos
        self.corrections = corrections
        self.typoCorrection = typoCorrection
    }
}
