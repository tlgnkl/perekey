// SPDX-License-Identifier: GPL-3.0-or-later

/// What the machine decided about one word, and on what grounds: kept only
/// by a machine made with `tracesJudgements`, for the replay of recorded
/// sessions (`InputMachine.lastJudgement`). One per word: at its end, or at
/// the letter a switch inside it happened on. Holds the word's keys, so it
/// stays in memory and is never written anywhere.
public struct JudgeTrace: Sendable {
    /// What happened to the word.
    public enum Action: Hashable, Sendable {
        /// Judged and left as typed.
        case kept
        /// Retyped in another layout; `early`: inside the word, at an
        /// impossible start ("ghb").
        case switched(to: LayoutID, early: Bool)
        /// Corrected in its own layout: a typo, "ё", a hyphen…
        case corrected(Correction.Kind)
        /// Not judged at all.
        case notJudged(Skip)
    }

    /// Why a word was not judged.
    public enum Skip: String, Hashable, Sendable, CaseIterable, Codable {
        /// Automatic switching and every word correction are off.
        case autoswitchOff
        /// The app is in «manual only» or «off».
        case appMode
        /// No language model.
        case noClassifier
        /// The focused element is not known yet, or not at all.
        case unknownFocus
        /// A password field has focus.
        case secureField
        /// Secure Input is on.
        case secureInput
        /// Typed partly in another layout or with ⌥.
        case notPlain
        /// The user retyped the word by hand before its end, or its
        /// correction was cancelled: the word is left alone.
        case leftAlone
        /// No layout to switch the word to, and none to correct it in.
        case noOtherLayout
    }

    /// Counts the traces of one machine, from 1: tells a new one from the last.
    public var serial: Int
    /// The keys of the word as typed, without the key that ended it.
    public var keys: [KeyStroke]
    /// The layout the word was typed in.
    public var layout: LayoutID?
    /// What the classifier was told about the word; nil when it did not run.
    public var context: Classifier.Context?
    /// What it decided, explained (`explaining: true`); nil when it did not run.
    public var decision: Classifier.Decision?
    /// The bundle ID of the focus.
    public var app: String?
    public var action: Action
    /// The retype that carried the switch or the correction.
    public var seq: UInt32?

    public init(serial: Int, keys: [KeyStroke], layout: LayoutID?, context: Classifier.Context?,
                decision: Classifier.Decision?, app: String?, action: Action, seq: UInt32? = nil)
    {
        self.serial = serial
        self.keys = keys
        self.layout = layout
        self.context = context
        self.decision = decision
        self.app = app
        self.action = action
        self.seq = seq
    }
}
