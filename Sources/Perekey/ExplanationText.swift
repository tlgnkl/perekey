// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// An `Explanation` in the user's language: «“ghbdtn” — no such word in
/// English · “привет” is a common word in Russian · Edge of 38 bits at a
/// threshold of 10». The facts are chosen in the core; the words are here.
enum ExplanationText {
    /// One line per statement.
    static func lines(_ explanation: Explanation) -> [String] {
        explanation.statements.map(line)
    }

    static func line(_ statement: Explanation.Statement) -> String {
        switch statement {
        case let .reading(text, form, language):
            let `in` = languageIn(language)
            switch form {
            case .notWord: return String(localized: "“\(text)” is not a word")
            case .unknown: return String(localized: "“\(text)” is not a word \(`in`)")
            case .rare: return String(localized: "“\(text)” is a rare word \(`in`)")
            case .known: return String(localized: "“\(text)” is a common word \(`in`)")
            }
        case let .edge(score, needed, switched):
            let threshold = Int(needed.rounded())
            if score <= 0 {
                return String(localized: "The typed word is the better one, by \(bits(-score))")
            }
            return switched
                ? String(localized: "Edge of \(bits(score)) at a threshold of \(threshold)")
                : String(localized: "Edge of \(bits(score)), but it needed \(threshold)")
        case let .note(reason):
            return note(reason)
        case let .impossibleStart(text, language):
            return String(localized: "“\(text)” cannot start a word \(languageIn(language))")
        case let .typo(change):
            switch change {
            case .substitute: return String(localized: "One letter was wrong, and the fixed word is a known one")
            case .transpose: return String(localized: "Two letters were swapped, and the fixed word is a known one")
            case .delete: return String(localized: "One letter too many, and the fixed word is a known one")
            case .insert: return String(localized: "One letter was missing, and the fixed word is a known one")
            }
        case let .rule(kind):
            switch kind {
            case .capsLock: return String(localized: "Typed with Caps Lock on by mistake")
            case .doubleCapitals: return String(localized: "Two capitals at the start: Shift was held a key too long")
            case .abbreviation: return String(localized: "A known abbreviation: it goes in capitals")
            case .yo: return String(localized: "The dictionary spells this word with «ё»")
            case .layout, .typo: return ""
            }
        }
    }

    static func note(_ reason: Classifier.Reason) -> String {
        switch reason {
        case .empty: String(localized: "There was no word")
        case .unsupported: String(localized: "The two layouts are not two languages Perekey knows")
        case .tooLong: String(localized: "Too long to be a word")
        case .digits: String(localized: "The word has digits, and Perekey leaves such words alone")
        case .kept: String(localized: "The word is on a never-switch list")
        case .passwordLike: String(localized: "It looks like a password, so Perekey leaves it alone")
        case .codeLike: String(localized: "Neither reading is a word: it looks like code, a link or a path")
        case .noise: String(localized: "Neither reading is likely: it looks like a random string")
        case .mixedCase: String(localized: "Capitals inside the word and no common word to switch to: a name, a code or a captcha")
        case .bothPlausible: String(localized: "The typed word reads fine in its own language, and the other one is unknown")
        case .shortWord: String(localized: "A short word: the dictionary and the word before it decide")
        case .compared: ""
        }
    }

    /// The heading of the explanation of a word Perekey left alone or fixed.
    static func title(switched: Bool) -> String {
        switched ? String(localized: "Why?") : String(localized: "Why didn't Perekey fix it?")
    }

    /// "in English", "в английском".
    static func languageIn(_ code: String?) -> String {
        switch code {
        case "en": String(localized: "in English")
        case "ru": String(localized: "in Russian")
        case "uk": String(localized: "in Ukrainian")
        default: String(localized: "in this layout")
        }
    }

    /// "1 bit", "2 bits"; in Russian "1 бит", "2 бита", "5 бит".
    static func bits(_ value: Double) -> String {
        let count = Int(value.rounded())
        switch Plural.form(count, languageCode: Locale.current.language.languageCode?.identifier) {
        case .one: return String(localized: "\(count) bit")
        case .few: return String(localized: "\(count) bits (few)")
        case .other: return String(localized: "\(count) bits")
        }
    }

    enum Plural {
        case one, few, other

        /// The CLDR rule of the languages Perekey ships in.
        static func form(_ count: Int, languageCode: String?) -> Plural {
            let n = abs(count)
            switch languageCode {
            case "ru", "uk":
                if n % 10 == 1, n % 100 != 11 { return .one }
                if (2...4).contains(n % 10), !(12...14).contains(n % 100) { return .few }
                return .other
            default:
                return n == 1 ? .one : .other
            }
        }
    }
}
