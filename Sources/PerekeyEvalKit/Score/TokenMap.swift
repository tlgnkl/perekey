// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyDesk

/// Which token of `want` each event of the typist works on: the trace of a
/// system names events, the slices need tokens.
///
/// A character of a `type` step belongs to the token it ends up in; a space
/// or another whitespace character, to the token before it (it ends that
/// word). Any other step belongs to the token before the caret.
public struct TokenMap: Sendable {
    /// By step, then by character; `stepToken` for steps other than `type`.
    private var charTokens: [Int: [Int?]] = [:]
    private var stepTokens: [Int: Int?] = [:]
    /// The first event of each token.
    public private(set) var firstEvent: [Int: Int] = [:]
    private var eventTokens: [Int?] = []

    public init(_ item: EvalCase, events: [TypedEvent]) {
        var field = TextField()
        for (index, step) in item.allSteps.enumerated() {
            if case let .type(text, _) = step {
                var tokens: [Int?] = []
                for character in text {
                    field.insert(String(character))
                    tokens.append(Self.tokenBeforeCaret(field))
                }
                charTokens[index] = tokens
            } else {
                stepTokens[index] = Self.tokenBeforeCaret(field)
                TargetText.render([step], into: &field)
            }
        }
        for (index, typed) in events.enumerated() {
            var token: Int?
            if let step = typed.step {
                if let char = typed.char, let tokens = charTokens[step], char < tokens.count {
                    token = tokens[char]
                } else if let stepToken = stepTokens[step] {
                    token = stepToken
                }
            }
            eventTokens.append(token)
            if let token, firstEvent[token] == nil, case let .type(text, _)? = typed.step.map({ item.allSteps[$0] }),
               let char = typed.char, char < text.count, !Array(text)[char].isWhitespace
            {
                firstEvent[token] = index
            }
        }
    }

    /// The token of `want` (counted from the start, warm-up included) the
    /// event works on.
    public func token(ofEvent index: Int) -> Int? {
        index >= 0 && index < eventTokens.count ? eventTokens[index] : nil
    }

    private static func tokenBeforeCaret(_ field: TextField) -> Int? {
        let before = String(field.characters[..<field.caret])
        let count = Tokenizer.tokens(before).count
        return count > 0 ? count - 1 : nil
    }
}
