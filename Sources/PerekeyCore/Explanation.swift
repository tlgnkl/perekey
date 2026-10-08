// SPDX-License-Identifier: GPL-3.0-or-later

/// Why Perekey did, or did not, change a word, as a list of facts the app
/// turns into text («Why?» in the menu and the hint). Pure data: no text of
/// its own, so the words live in the app's localization and the choice of
/// facts is testable here.
///
/// «ghbdtn — no such English word · привет — a frequent Russian word · edge
/// of 38 bits at a threshold of 10».
public struct Explanation: Equatable, Sendable {
    public enum Statement: Equatable, Sendable {
        /// What a reading of the keys is as a word of its language.
        case reading(text: String, form: Classifier.Form, language: String?)
        /// How far the other reading was ahead, in bits, and what it needed.
        case edge(score: Double, needed: Double, switched: Bool)
        /// A guard or another reason that is no comparison.
        case note(Classifier.Reason)
        /// The start of the word cannot begin a word of its layout.
        case impossibleStart(text: String, language: String?)
        /// A typo correction and what it changed.
        case typo(TypoCorrector.Change)
        /// A word correction that follows a fixed rule.
        case rule(Correction.Kind)
    }

    public var statements: [Statement]
    /// Whether the word was (or would have been) switched.
    public var switched: Bool

    public init(statements: [Statement], switched: Bool) {
        self.statements = statements
        self.switched = switched
    }

    /// Why an automatic correction happened.
    public init(correction: Correction) {
        var statements: [Statement] = []
        if correction.insideWord {
            statements.append(.impossibleStart(text: correction.original, language: correction.decision?.typedLanguage))
        } else if let decision = correction.decision, decision.verdict != .keep, decision.verdict != .unsure {
            statements = Self.facts(of: decision, typed: correction.original, other: correction.replacement)
        }
        if let change = correction.typoChange {
            statements.append(.typo(change))
        } else if correction.kind != .layout, correction.kind != .typo {
            statements.append(.rule(correction.kind))
        }
        self.init(statements: statements, switched: true)
    }

    /// Why automatic switching decided as it did about a word: `typed` is the
    /// word as typed, `other` as the other layout reads it.
    public init(decision: Classifier.Decision, typed: String, other: String) {
        var switched = false
        if case .switch = decision.verdict { switched = true }
        self.init(statements: Self.facts(of: decision, typed: typed, other: other), switched: switched)
    }

    private static func facts(of decision: Classifier.Decision, typed: String, other: String) -> [Statement] {
        let readings: [Statement] = [
            .reading(text: typed, form: decision.typedForm, language: decision.typedLanguage),
            .reading(text: other, form: decision.otherForm, language: decision.otherLanguage),
        ]
        let switched: Bool
        if case .switch = decision.verdict { switched = true } else { switched = false }
        switch decision.reason {
        case .empty, .unsupported, .tooLong, .digits, .kept, .passwordLike:
            // A guard: the readings say nothing about it.
            return [.note(decision.reason)]
        case .codeLike, .noise, .mixedCase, .bothPlausible, .shortWord:
            return readings + [.note(decision.reason)]
        case .compared:
            guard decision.score.isFinite else {
                // The other reading is no word: nothing to compare.
                return [readings[1]]
            }
            return readings + [.edge(score: decision.score, needed: decision.margin, switched: switched)]
        }
    }
}
