// SPDX-License-Identifier: GPL-3.0-or-later

/// What a fresh `InputMachine` needs to go on exactly as another one, taken
/// at a quiet point (`InputMachine.isQuiet`): no word in the buffer, no
/// retype in flight, no undo waiting. A session segment starts with one
/// (`SessionSnapshot`), so a replay can start at any segment.
///
/// No typed text: settings, layouts, the focus and the counts of languages,
/// as the machine has them. The classifier is described apart
/// (`ClassifierSpec`): its model is not recorded.
public struct MachineSnapshot: Hashable, Sendable, Codable {
    public var settings: Settings
    /// The enabled layouts in the system's order.
    public var layouts: [LayoutMap]
    public var currentLayout: LayoutID?
    /// The layouts in the order the user last selected them (`LayoutState.used`).
    public var usedLayouts: [LayoutID]
    /// The layout the system last reported, and the ones Perekey selected
    /// that it has not confirmed yet (`Fence`).
    public var confirmedLayout: LayoutID?
    public var pendingSelections: [LayoutID]
    /// The `seq` of the next retype.
    public var nextSeq: UInt32
    public var focus: Focus?
    public var appMode: AppMode
    public var secureInput: Bool
    public var voiceSession: Bool
    public var dictationTyping: Bool
    public var languageContext: LanguageContext
    /// The languages of the last judged words, the latest first (`RecentLanguages`).
    public var recentLanguages: [String?]
    /// The next word starts a sentence.
    public var sentenceStart: Bool
    /// Words judged since the last `Effect.languagesCounted`, by language.
    public var tally: [String: Int]
    public var tallied: Int
}
