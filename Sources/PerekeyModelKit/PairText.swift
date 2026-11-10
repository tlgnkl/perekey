// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Words and sentences of running text, the way the pair counts read them
/// (docs/classifier.md, «Пары слов»).
///
/// A word is what `Coverage.words(of:)` calls one: letters and digits with
/// apostrophes and hyphens inside, none at the ends. Its fingerprint is the
/// folded one of the model (`ModelFormat.Fingerprint`); `’` reads as `'`, as
/// `Coverage.measure` reads it. A sentence ends at `.`, `!`, `?`, `…`, a tab
/// (the paragraph mark `scripts/wiki-text.py` writes) and a line end. Commas,
/// dashes, brackets and quotes do not end it: the word before the comma is
/// still the word before.
///
/// The scanner reads UTF-8 bytes without making a `String` or a `Character`:
/// 50 million words of Wikipedia take a minute, not ten.
public enum PairText {
    public enum Event: Equatable, Sendable {
        /// A word: the folded fingerprint.
        case word(UInt64)
        /// The end of a sentence. Sent once per sentence that had a word.
        case sentenceEnd
    }

    /// Calls `emit` for every word and sentence end of `text`, in order. The
    /// text ends a sentence too: a line is a whole article or less.
    public static func scan(_ text: UnsafeRawBufferPointer, _ emit: (Event) -> Void) {
        var scanner = Scanner()
        var index = 0
        let count = text.count
        while index < count {
            let byte = text[index]
            if byte < 0x80 {
                index += 1
                scanner.add(UInt32(byte), emit)
                continue
            }
            // A damaged sequence is one separator, U+FFFD, and does not stop the scan.
            let (scalar, length) = decode(text, at: index, byte: byte)
            index += length
            scanner.add(scalar, emit)
        }
        scanner.finish(emit)
    }

    public static func scan(_ text: String, _ emit: (Event) -> Void) {
        var text = text
        text.withUTF8 { scan(UnsafeRawBufferPointer($0), emit) }
    }

    /// The scalar at `index` and the bytes it takes. Never reads past the end.
    private static func decode(_ text: UnsafeRawBufferPointer, at index: Int, byte: UInt8) -> (UInt32, Int) {
        let count = text.count
        let replacement: UInt32 = 0xFFFD
        func continuation(_ offset: Int) -> UInt32? {
            guard index + offset < count, text[index + offset] & 0xC0 == 0x80 else { return nil }
            return UInt32(text[index + offset] & 0x3F)
        }
        switch byte {
        case 0xC2...0xDF:
            guard let b1 = continuation(1) else { return (replacement, 1) }
            return (UInt32(byte & 0x1F) << 6 | b1, 2)
        case 0xE0...0xEF:
            guard let b1 = continuation(1), let b2 = continuation(2) else { return (replacement, 1) }
            let scalar = UInt32(byte & 0x0F) << 12 | b1 << 6 | b2
            return scalar < 0x800 || (0xD800...0xDFFF).contains(scalar) ? (replacement, 1) : (scalar, 3)
        case 0xF0...0xF4:
            guard let b1 = continuation(1), let b2 = continuation(2), let b3 = continuation(3) else {
                return (replacement, 1)
            }
            let scalar = UInt32(byte & 0x07) << 18 | b1 << 12 | b2 << 6 | b3
            return scalar < 0x10000 || scalar > 0x10FFFF ? (replacement, 1) : (scalar, 4)
        default:
            return (replacement, 1)
        }
    }

    /// The state of the scan: the word being read and the joiners waiting
    /// behind its last letter.
    private struct Scanner {
        var fingerprint = ModelFormat.Fingerprint()
        var inWord = false
        /// Apostrophes and hyphens after the last letter: part of the word
        /// when a letter follows, dropped when the word ends.
        var joiners: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var joinerCount = 0
        var sentenceHasWord = false

        mutating func add(_ scalar: UInt32, _ emit: (Event) -> Void) {
            switch PairText.kind(of: scalar) {
            case .letter:
                if inWord { flushJoiners() }
                inWord = true
                joinerCount = 0
                fingerprint.add(ModelFormat.fold(scalar))
            case .joiner:
                guard inWord else { return }
                if joinerCount == 4 {
                    // "a-----b" is no word of any language: end the token here.
                    endWord(emit)
                    return
                }
                switch joinerCount {
                case 0: joiners.0 = scalar
                case 1: joiners.1 = scalar
                case 2: joiners.2 = scalar
                default: joiners.3 = scalar
                }
                joinerCount += 1
            case .separator:
                endWord(emit)
            case .sentenceEnd:
                endWord(emit)
                endSentence(emit)
            }
        }

        mutating func flushJoiners() {
            let pending = [joiners.0, joiners.1, joiners.2, joiners.3]
            for scalar in pending.prefix(joinerCount) {
                fingerprint.add(scalar == 0x2019 ? 0x27 : ModelFormat.fold(scalar))
            }
            joinerCount = 0
        }

        mutating func endWord(_ emit: (Event) -> Void) {
            guard inWord else { return }
            emit(.word(fingerprint.value))
            sentenceHasWord = true
            fingerprint = ModelFormat.Fingerprint()
            inWord = false
            joinerCount = 0
        }

        mutating func endSentence(_ emit: (Event) -> Void) {
            guard sentenceHasWord else { return }
            emit(.sentenceEnd)
            sentenceHasWord = false
        }

        mutating func finish(_ emit: (Event) -> Void) {
            endWord(emit)
            endSentence(emit)
        }
    }

    private enum Kind {
        case letter, joiner, separator, sentenceEnd
    }

    private static func kind(of scalar: UInt32) -> Kind {
        if scalar < 0x80 {
            switch scalar {
            case 0x61...0x7A, 0x41...0x5A, 0x30...0x39: return .letter
            case 0x27, 0x2D: return .joiner
            case 0x2E, 0x21, 0x3F, 0x09, 0x0A, 0x0D: return .sentenceEnd
            default: return .separator
            }
        }
        switch scalar {
        case 0x2019, 0x2BC: return .joiner
        case 0x2026, 0x2029: return .sentenceEnd
        default: break
        }
        guard let value = Unicode.Scalar(scalar) else { return .separator }
        switch value.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             // Accents and stress marks stay in the word, which then is no word of the model.
             .nonspacingMark, .spacingMark, .enclosingMark:
            return .letter
        default:
            return .separator
        }
    }
}
