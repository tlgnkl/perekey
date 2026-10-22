// SPDX-License-Identifier: GPL-3.0-or-later

/// Learning from undone corrections by evidence, not from one undo
/// (docs/classifier.md, «Обучение»).
///
/// One undo used to put the word on "Не трогать: выученные" for ever, and a
/// Backspace meant for the space after a correction ("jrtq " → "окей ", then
/// Backspace to put a comma) taught "jrtq". Now each undo of a word adds
/// evidence (`LearningOptions`): the hint's button and the shortcuts are
/// sure, a Backspace counts only once what comes after it says the user
/// kept the word (`UndoWatch`). At the threshold of the undone decision
/// (`threshold(for:options:frequentRank:)`) the app asks the user
/// (`WordRules.count`), and the answer sets the scope: this app or everywhere.
public struct LearningOptions: Hashable, Sendable {
    /// Evidence of an undo by the hint's button or a shortcut.
    public var explicitWeight = 2
    /// Evidence of a Backspace undo, once the user typed on with the word as typed.
    public var backspaceWeight = 1
    /// Evidence an undo adds on another calendar day than the last counted one.
    public var newDayBonus = 1
    /// The threshold when the typed reading is a word of its own language
    /// (a known or rare form): the user likely meant it.
    public var plausibleThreshold = 1
    /// The threshold when the typed reading is noise and the other one an
    /// ordinary word, and for corrections without a classifier's decision.
    public var ordinaryThreshold = 2
    /// The threshold when the other reading is frequent
    /// (`Classifier.Options.shortWordRank`, Zipf 5): the switch was likely right.
    public var frequentThreshold = 3
    /// A candidate with no counted undo for this long is dropped, in seconds.
    public var candidateLifetime: Double = 30 * 86_400
    /// A word learned in this many apps is learned everywhere.
    public var appsForEverywhere = 2

    public init() {}

    /// The evidence one undo gives, before the day bonus.
    public func weight(_ channel: UndoChannel, _ followUp: UndoFollowUp) -> Int {
        switch channel {
        case .button, .shortcut: explicitWeight
        case .backspace: followUp == .continued ? backspaceWeight : 0
        }
    }

    /// How much evidence it takes to ask about a word, by what the
    /// classifier made of the correction the user undid. `frequentRank` is
    /// the classifier's `shortWordRank`. A correction without a decision (a
    /// typo, «ё», a switch inside the word) takes `ordinaryThreshold`.
    public func threshold(for decision: Classifier.Decision?, frequentRank: UInt8) -> Int {
        guard let decision else { return ordinaryThreshold }
        switch decision.typedForm {
        case .known, .rare: return plausibleThreshold
        case .unknown, .notWord: break
        }
        return (decision.otherRank ?? 0) >= frequentRank ? frequentThreshold : ordinaryThreshold
    }
}

/// How the user undid a correction.
public enum UndoChannel: String, Hashable, Sendable, Codable {
    /// The hint's «Отменить» (`InputEvent.undoLastCorrection`).
    case button
    /// `HotkeyAction.undoLastCorrection`, or the retype shortcut right after the correction.
    case shortcut
    /// Backspace right after the correction: maybe meant for the key after the word.
    case backspace
}

/// What the user did right after a Backspace undo, which says what the
/// Backspace meant.
public enum UndoFollowUp: String, Hashable, Sendable, Codable {
    /// Not watched: the button and the shortcuts are meant as undos.
    case none
    /// Typed on with the word left as typed: a space or the next word. Counts.
    case continued
    /// Punctuation right after the word: the Backspace was for the space.
    case punctuation
    /// Retyped the word with the shortcut: the correction was right.
    case retyped
    /// Deleted into the word or typed onto it: likely retyping it corrected.
    case edited
    /// The caret may have moved: a click, a focus or app change, an arrow, a shortcut.
    case unknown
}

/// The facts of an undone decision, for the shadow journal: no text.
public struct UndoFacts: Hashable, Sendable, Codable {
    public var kind: String
    public var reason: String?
    /// Bits in favour of the other reading; nil without a decision or when it was no word.
    public var score: Double?
    public var typedForm: String?
    public var otherForm: String?
    public var typedRank: UInt8?
    public var otherRank: UInt8?
    public var typedLanguage: String?
    public var otherLanguage: String?

    public init(kind: Correction.Kind, decision: Classifier.Decision?) {
        self.kind = "\(kind)"
        guard let decision else { return }
        reason = "\(decision.reason)"
        score = decision.score.isFinite ? decision.score : nil
        typedForm = "\(decision.typedForm)"
        otherForm = "\(decision.otherForm)"
        typedRank = decision.typedRank
        otherRank = decision.otherRank
        typedLanguage = decision.typedLanguage
        otherLanguage = decision.otherLanguage
    }
}

/// An undone correction, once it is known what it says (`Effect.undoSettled`).
public struct UndoReport: Hashable, Sendable {
    /// The word to count, normalized (`CorrectionUndo.learnable`). Never logged or journaled.
    public var word: String
    /// The bundle ID of the focus the word was typed in; nil when unknown.
    public var app: String?
    public var channel: UndoChannel
    public var followUp: UndoFollowUp
    /// The evidence it takes to ask about the word (`LearningOptions.threshold`).
    public var threshold: Int
    public var facts: UndoFacts

    public init(word: String, app: String?, channel: UndoChannel, followUp: UndoFollowUp = .none, threshold: Int,
                facts: UndoFacts)
    {
        self.word = word
        self.app = app
        self.channel = channel
        self.followUp = followUp
        self.threshold = threshold
        self.facts = facts
    }
}

/// A Backspace undo of a finished word, waiting for the key after it.
///
/// The undo puts back the word and the key that ended it ("jrtq "). What
/// comes next says what the Backspace was for: a space or the next word
/// keeps the word as typed (`continued`); a Backspace deletes the space, and
/// punctuation then means the user only wanted the space gone; a Backspace
/// into the word, letters onto it, the retype shortcut or anything that may
/// move the caret count nothing.
struct UndoWatch: Sendable {
    var report: UndoReport
    /// The key that ended the word is still after it.
    var boundaryLeft: Bool

    /// A key down by the user, typed in `map` (the layout the undo selected).
    /// Returns the report once settled; nil while it still waits.
    mutating func keyDown(_ key: KeyEvent, held: UInt8, in map: LayoutMap?) -> UndoReport? {
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        let shortcut = held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit) != 0
        // Return and Tab are navigation keys too, but they end the line after the word kept as typed.
        if !shortcut, key.keyCode == KeyCode.space || WordJudge.endsLine(key) { return settle(.continued) }
        if shortcut || KeyCode.navigation.contains(key.keyCode) { return settle(.unknown) }
        if key.keyCode == KeyCode.delete {
            // ⌥⌫ deletes a whole word, not the space.
            guard boundaryLeft, held & ModifierKind.option.maskBit == 0 else { return settle(.edited) }
            boundaryLeft = false
            return nil
        }
        // Esc, F-keys, Help and the like type nothing: the caret or the text may be anywhere.
        guard let map, let scalar = Self.printable(stroke, in: map) else { return settle(.unknown) }
        // The space is still there: whatever is typed after it is the next word, «(пояснение)», «- пункт», «/путь» too.
        if boundaryLeft { return settle(.continued) }
        // The space is gone. Anything but a letter or digit: «-», «(», «/», «—», «'», «]» only wanted the space gone.
        if !scalar.properties.isAlphabetic, scalar.properties.numericType == nil { return settle(.punctuation) }
        // A letter without the space: more of this word.
        return settle(.edited)
    }

    /// The one printable character the stroke types in `map`; nil for no text, several characters or a control.
    private static func printable(_ stroke: KeyStroke, in map: LayoutMap) -> Unicode.Scalar? {
        guard let text = map.text(for: stroke) else { return nil }
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return nil }
        switch scalar.properties.generalCategory {
        case .control, .format, .unassigned, .privateUse, .surrogate: return nil
        default: return scalar
        }
    }

    func settle(_ followUp: UndoFollowUp) -> UndoReport {
        var report = report
        report.followUp = followUp
        return report
    }
}

/// What counting an undo did (`WordRules.count`), for the app and the journal.
public struct LearningStep: Hashable, Sendable {
    public enum Outcome: String, Hashable, Sendable, Codable {
        /// `learnFromUndos` is off.
        case off
        /// The word is no word for the lists, or is on "Мои".
        case notLearnable
        /// Withdrawn from "Всегда исправлять" instead: the latest explicit signal wins.
        case withdrawn
        /// Already learned for this app or everywhere: one more undo on it.
        case alreadyLearned
        /// The undo gave no evidence (`LearningOptions.weight`).
        case noEvidence
        /// Counted, below the threshold.
        case counted
        /// At the threshold: ask the user (`question`).
        case ask
    }

    /// What the rule before evidence did with the same undo: learn the word
    /// everywhere at once, count one more undo of a learned word, or nothing.
    public enum OldRule: String, Hashable, Sendable, Codable {
        case learn, count, withdraw, nothing
    }

    public var outcome: Outcome
    /// The word's evidence in this app after the undo.
    public var evidence: Int
    public var threshold: Int
    public var oldRule: OldRule
    public var question: LearningQuestion?

    public init(outcome: Outcome, evidence: Int = 0, threshold: Int = 0, oldRule: OldRule,
                question: LearningQuestion? = nil)
    {
        self.outcome = outcome
        self.evidence = evidence
        self.threshold = threshold
        self.oldRule = oldRule
        self.question = question
    }
}

/// «Больше не менять “jrtq”? Только здесь / Везде / Нет»: the word reached
/// its threshold. The answer goes to `WordRules.answer`.
public struct LearningQuestion: Hashable, Sendable {
    public var word: String
    /// The app it was asked in; nil when the focus was unknown, and "Только здесь" then means everywhere.
    public var app: String?
    /// The word is learned, or at its threshold, in another app too:
    /// "Только здесь" makes it learned everywhere (`LearningOptions.appsForEverywhere`).
    public var reachedElsewhere: Bool

    public init(word: String, app: String?, reachedElsewhere: Bool = false) {
        self.word = word
        self.app = app
        self.reachedElsewhere = reachedElsewhere
    }
}

/// The user's answer to a `LearningQuestion`.
public enum LearningAnswer: String, Hashable, Sendable, Codable {
    /// «Только здесь»: never correct the word in this app.
    case here
    /// «Везде».
    case everywhere
    /// «Нет»: keep correcting; the evidence starts over.
    case no
}

/// A learned word the user retyped by hand into the other layout
/// (`WordRules.unlearn`): it is corrected again from now on.
public struct Unlearned: Hashable, Sendable {
    public var word: String
    /// The app it was learned for; nil when it was learned everywhere.
    public var app: String?

    public init(word: String, app: String?) {
        self.word = word
        self.app = app
    }
}
