// SPDX-License-Identifier: GPL-3.0-or-later

/// What a key press means to the caret hint. Only the kind is kept, never the
/// character: the hint must not hold on to what the user types.
public enum HintKey: Sendable {
    /// A letter or digit of the word being typed.
    case wordCharacter
    /// Space, Return, Tab or punctuation: the word ends.
    case wordBoundary
    case delete
    /// Arrows, shortcuts, modifiers: activity that says nothing about words.
    case other

    /// Sorts a key press. `character` is the first character the key types;
    /// a press with ⌘ or ⌃ is a shortcut, not text.
    public static func classify(keyCode: UInt16, character: Character?, isShortcut: Bool) -> HintKey {
        if isShortcut { return .other }
        switch keyCode {
        case 36, 48, 76: return .wordBoundary // Return, Tab, keypad Enter
        case 51, 117: return .delete
        case 53, 123 ... 126: return .other // Escape, arrows
        default: break
        }
        guard let character else { return .other }
        if character.isLetter || character.isNumber || character == "'" || character == "’" { return .wordCharacter }
        if character.isWhitespace || character.isPunctuation || character.isSymbol { return .wordBoundary }
        return .other
    }
}

/// When the caret hint goes away: once the next word is typed in full, or
/// `idle` seconds after the last key press. The pointer over the hint holds
/// it. Pure state on a clock the caller passes in (seconds, any epoch).
public struct HintLifetime: Equatable, Sendable {
    public static let idle: Double = 3

    private let idleSeconds: Double
    private var deadline: Double
    /// Seconds left when the pointer arrived; nil while it is away.
    private var frozen: Double?
    private var wordCharacters = 0
    private var wordDone = false

    public init(idle: Double = HintLifetime.idle, now: Double) {
        idleSeconds = idle
        deadline = now + idle
    }

    /// A new hint replaced the old one: count from scratch. The pointer stays
    /// where it is, so a hovered hint stays hovered.
    public mutating func restart(at now: Double) {
        wordCharacters = 0
        wordDone = false
        if frozen != nil { frozen = idleSeconds } else { deadline = now + idleSeconds }
    }

    public mutating func record(_ key: HintKey, at now: Double) {
        if frozen != nil { frozen = idleSeconds } else { deadline = now + idleSeconds }
        switch key {
        case .wordCharacter:
            wordCharacters += 1
        case .wordBoundary:
            if wordCharacters > 0 { wordDone = true }
            wordCharacters = 0
        case .delete:
            wordCharacters = max(0, wordCharacters - 1)
        case .other:
            break
        }
    }

    /// Keeps the hint at least `seconds` from now: the user opened something
    /// to read.
    public mutating func hold(for seconds: Double, at now: Double) {
        if let left = frozen {
            frozen = max(left, seconds)
        } else {
            deadline = max(deadline, now + seconds)
        }
    }

    public mutating func setHovering(_ hovering: Bool, at now: Double) {
        if hovering, frozen == nil {
            frozen = max(0, deadline - now)
        } else if !hovering, let left = frozen {
            frozen = nil
            deadline = now + left
        }
    }

    public func isExpired(at now: Double) -> Bool {
        if frozen != nil { return false }
        return wordDone || now >= deadline
    }
}
