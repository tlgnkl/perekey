// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyModelKit

extension Typist {
    /// A typist that looks at the field after each token and answers what it
    /// sees (docs/eval.md, «Обучение»). The `Typist` itself is a function of
    /// a case; a person who reads the text is not, so the reactor is a state
    /// of its own: a seeded generator (`SplitMix64`) and the shares of the
    /// manifest.
    ///
    /// What it answers:
    ///
    /// - The token is as meant and Perekey did not touch it: nothing.
    /// - The token is as meant and Perekey corrected it, rightly: usually
    ///   nothing; with the share `accident` a Backspace meant for the space
    ///   undoes the correction («jrtq » → «окей », Backspace, to put a comma).
    /// - The token is not as meant and Perekey corrected it (harm): the
    ///   person undoes it, by Backspace with the share `backspaceShare`, by
    ///   the hint's button otherwise.
    /// - The token is not as meant and Perekey left it (a miss): the person
    ///   retypes it with `convertLastWord`.
    public struct Reactor {
        /// Every number is a model of a person, not a measurement.
        public struct Options: Hashable, Sendable {
            /// Of the undos of a wrong correction, the share made by
            /// Backspace; the rest use the hint's button. No data: a guess,
            /// swept in docs/eval.md.
            public var backspaceShare = 0.5
            /// Of the right corrections, the share followed by a Backspace
            /// meant for the space before a comma. «jrtq» was one such Backspace.
            public var accident = 0.0
            /// Of those Backspaces, the share after which the person does not
            /// type the comma but goes on: the word stays as typed, which
            /// counts as evidence, and the wrong word is left in the text.
            public var accidentContinues = 0.0
            /// Of those Backspaces, the share after which the person sees the
            /// word come back and retypes it with `convertLastWord`: no evidence.
            /// The rest type the comma, and the word stays wrong: no evidence either.
            public var accidentRetypes = 0.0
            /// Seconds from the end of the token to the person's answer: the
            /// time to see the text.
            public var reaction = 0.5

            public init() {}
        }

        /// What the person sees after a token.
        public struct Seen: Hashable, Sendable {
            /// The text before the caret ends with what was meant.
            public var asMeant: Bool
            /// Perekey corrected the token (a hint was shown for it).
            public var corrected: Bool

            public init(asMeant: Bool, corrected: Bool) {
                self.asMeant = asMeant
                self.corrected = corrected
            }
        }

        public enum Reaction: Hashable, Sendable {
            case nothing
            case undoByBackspace
            case undoByButton
            /// `convertLastWord`.
            case convert
            /// A Backspace for the space, which undoes the correction; `then`
            /// is what the person does when the word comes back.
            case accidentalBackspace(then: AccidentEnd)
        }

        public enum AccidentEnd: Hashable, Sendable {
            /// Deletes the space and types the comma («jrtq,»).
            case punctuation
            /// Types on: Return, the next word.
            case continues
            /// Retypes the word with the shortcut.
            case retype
        }

        public let options: Options
        private var random: SplitMix64

        public init(options: Options = Options(), seed: UInt64) {
            self.options = options
            random = SplitMix64(seed: seed)
        }

        /// A number in [0, 1), the same count of draws for every answer.
        private mutating func draw() -> Double {
            Double(random.next() >> 11) / Double(1 << 53)
        }

        public mutating func react(_ seen: Seen) -> Reaction {
            let first = draw(), second = draw()
            switch (seen.asMeant, seen.corrected) {
            case (true, false):
                return .nothing
            case (true, true):
                guard first < options.accident else { return .nothing }
                if second < options.accidentContinues { return .accidentalBackspace(then: .continues) }
                if second < options.accidentContinues + options.accidentRetypes { return .accidentalBackspace(then: .retype) }
                return .accidentalBackspace(then: .punctuation)
            case (false, true):
                return first < options.backspaceShare ? .undoByBackspace : .undoByButton
            case (false, false):
                return .convert
            }
        }
    }
}
