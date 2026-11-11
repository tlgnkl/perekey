// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The text of a source, made ready for the builder: Stack Exchange HTML to
/// paragraphs, paragraphs to sentences (docs/eval.md, «Читатели»).
///
/// Everything here runs on UTF-8 bytes. A dump is a gigabyte of rows, and
/// the work on `Character`s (grapheme breaking, normalization) costs ten
/// times as much as the work on bytes. Only the few places that must look at
/// a letter decode a scalar.
public enum SourceText {
    /// Wrap the words of an inline `<code>`: the builder tags their tokens
    /// `code` and takes the marks off. Private-use characters, which no
    /// source text has.
    public static let codeOpen: Character = "\u{E000}"
    public static let codeClose: Character = "\u{E001}"

    static let codeOpenBytes: [UInt8] = [0xEE, 0x80, 0x80]
    static let codeCloseBytes: [UInt8] = [0xEE, 0x80, 0x81]

    // MARK: - HTML

    /// The paragraphs of a post body, as the XML attribute `Body` holds it:
    /// `<pre>…</pre>` blocks are cut out whole, `<code>…</code>` in a line
    /// stays between `codeOpen` and `codeClose`, block tags end a paragraph,
    /// other tags fall away without a space, entities are read, runs of white
    /// space become one space. Empty paragraphs are not returned.
    public static func paragraphs(fromBody body: String) -> [String] {
        paragraphBytes(fromBody: Array(body.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func paragraphBytes(fromBody body: [UInt8]) -> [[UInt8]] {
        let html = unescape(body)
        var text: [UInt8] = []
        text.reserveCapacity(html.count)
        var index = 0
        while index < html.count {
            let byte = html[index]
            guard byte == UInt8(ascii: "<"), let close = html[index...].firstIndex(of: UInt8(ascii: ">")) else {
                text.append(byte)
                index += 1
                continue
            }
            var position = index + 1
            let closing = position < close && html[position] == UInt8(ascii: "/")
            if closing { position += 1 }
            var name: [UInt8] = []
            while position < close, isASCIIAlphanumeric(html[position]) {
                name.append(html[position] | 0x20)
                position += 1
            }
            if name == preName, !closing {
                // A block of code is not prose in either language: cut it whole.
                if let end = find(preClose, in: html, from: close) {
                    text.append(newline)
                    index = end + preClose.count
                    continue
                }
            } else if name == codeName {
                text.append(contentsOf: closing ? codeCloseBytes : codeOpenBytes)
            } else if blockTags.contains(name) {
                text.append(newline)
            }
            index = close + 1
        }
        var paragraphs: [[UInt8]] = []
        for chunk in unescape(text).split(separator: newline, omittingEmptySubsequences: true) {
            let line = collapseSpace(chunk)
            if !line.isEmpty { paragraphs.append(line) }
        }
        return paragraphs
    }

    private static let newline: UInt8 = 0x0A
    private static let preName = Array("pre".utf8)
    private static let codeName = Array("code".utf8)
    private static let preClose = Array("</pre>".utf8)

    private static let blockTags: Set<[UInt8]> = Set(
        ["p", "br", "li", "ul", "ol", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "div", "hr", "tr", "table"]
            .map { Array($0.utf8) })

    private static let namedEntities: [[UInt8]: [UInt8]] = Dictionary(uniqueKeysWithValues: [
        ("lt", "<"), ("gt", ">"), ("amp", "&"), ("quot", "\""), ("apos", "'"), ("nbsp", " "), ("laquo", "«"),
        ("raquo", "»"), ("mdash", "—"), ("ndash", "–"), ("hellip", "…"),
    ].map { (Array($0.0.utf8), Array($0.1.utf8)) })

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// The first place of `pattern` in `text` at or after `from`.
    private static func find(_ pattern: [UInt8], in text: [UInt8], from: Int) -> Int? {
        guard let first = pattern.first, text.count >= pattern.count, from <= text.count - pattern.count else { return nil }
        var index = from
        while index <= text.count - pattern.count {
            if text[index] == first, text[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }

    /// White space becomes one space, at the ends it falls away. Tab, CR,
    /// space and the no-break space count.
    private static func collapseSpace(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        var line: [UInt8] = []
        line.reserveCapacity(chunk.count)
        var pending = false
        var index = chunk.startIndex
        while index < chunk.endIndex {
            let byte = chunk[index]
            var width = 1
            var space = byte == 0x20 || byte == 0x09 || byte == 0x0D
            if byte == 0xC2, index + 1 < chunk.endIndex, chunk[index + 1] == 0xA0 {
                space = true
                width = 2
            }
            if space {
                pending = !line.isEmpty
            } else {
                if pending { line.append(0x20) }
                pending = false
                line.append(byte)
            }
            index += width
        }
        return line
    }

    /// XML character references and the entities of `namedEntities`; what is
    /// not one stays as it is.
    public static func unescapeXML(_ text: String) -> String {
        String(decoding: unescape(Array(text.utf8)), as: UTF8.self)
    }

    static func unescape(_ text: [UInt8]) -> [UInt8] {
        guard text.contains(UInt8(ascii: "&")) else { return text }
        var result: [UInt8] = []
        result.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            let byte = text[index]
            guard byte == UInt8(ascii: "&"),
                  let semicolon = text[index..<min(index + 11, text.count)].firstIndex(of: UInt8(ascii: ";"))
            else {
                result.append(byte)
                index += 1
                continue
            }
            let name = Array(text[(index + 1)..<semicolon])
            if let named = namedEntities[name] {
                result.append(contentsOf: named)
            } else if let scalar = numericReference(name) {
                result.append(contentsOf: Array(String(Character(scalar)).utf8))
            } else {
                result.append(contentsOf: text[index...semicolon])
            }
            index = semicolon + 1
        }
        return result
    }

    private static func numericReference(_ name: [UInt8]) -> Unicode.Scalar? {
        guard name.first == UInt8(ascii: "#") else { return nil }
        let digits = String(decoding: name.dropFirst(), as: UTF8.self)
        let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init)
    }

    // MARK: - Sentences

    /// Sentences of a paragraph: it is cut after `.`, `!` or `?` (and the
    /// closing quotes and brackets after it) that a space and a capital letter
    /// or a digit follow. A single letter before the dot («т. д.», «А. С.
    /// Пушкин») is an abbreviation, not an end.
    public static func sentences(of paragraph: String) -> [String] {
        let bytes = Array(paragraph.utf8)
        return sentenceRanges(in: bytes).map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    /// The byte ranges of the sentences of a paragraph, without the spaces at their ends.
    static func sentenceRanges(in bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var index = 0
        func emit(_ end: Int) {
            var from = start, to = end
            while from < to, bytes[from] == 0x20 { from += 1 }
            while to > from, bytes[to - 1] == 0x20 { to -= 1 }
            if from < to { ranges.append(from..<to) }
        }
        while index < bytes.count {
            guard isStop(bytes[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count {
                if isStop(bytes[end]) {
                    end += 1
                } else if let width = closerWidth(bytes, at: end) {
                    end += width
                } else {
                    break
                }
            }
            guard end < bytes.count, bytes[end] == 0x20 else {
                index = end
                continue
            }
            var next = end
            while next < bytes.count, bytes[next] == 0x20 { next += 1 }
            while next < bytes.count, let width = openerWidth(bytes, at: next) { next += width }
            guard next < bytes.count, let (scalar, _) = scalar(in: bytes, at: next),
                  scalar.properties.isUppercase || scalar.properties.numericType != nil
            else {
                index = end
                continue
            }
            if bytes[index] == UInt8(ascii: "."), isAbbreviation(bytes, dot: index) {
                index = end
                continue
            }
            emit(end)
            start = next
            index = next
        }
        emit(bytes.count)
        return ranges
    }

    private static func isStop(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: ".") || byte == UInt8(ascii: "!") || byte == UInt8(ascii: "?")
    }

    /// A closing bracket or quote after a stop: ) ] " ' » ” and the end of inline code.
    private static func closerWidth(_ bytes: [UInt8], at index: Int) -> Int? {
        switch bytes[index] {
        case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "\""), UInt8(ascii: "'"): return 1
        case 0xC2 where index + 1 < bytes.count && bytes[index + 1] == 0xBB: return 2
        case 0xE2 where index + 2 < bytes.count && bytes[index + 1] == 0x80 && bytes[index + 2] == 0x9D: return 3
        case 0xEE where index + 2 < bytes.count && bytes[index + 1] == 0x80 && bytes[index + 2] == 0x81: return 3
        default: return nil
        }
    }

    /// An opening bracket or quote before a sentence: ( [ " « “ and the start of inline code.
    private static func openerWidth(_ bytes: [UInt8], at index: Int) -> Int? {
        switch bytes[index] {
        case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "\""): return 1
        case 0xC2 where index + 1 < bytes.count && bytes[index + 1] == 0xAB: return 2
        case 0xE2 where index + 2 < bytes.count && bytes[index + 1] == 0x80 && bytes[index + 2] == 0x9C: return 3
        case 0xEE where index + 2 < bytes.count && bytes[index + 1] == 0x80 && bytes[index + 2] == 0x80: return 3
        default: return nil
        }
    }

    /// The scalar that starts at `index`, and its width.
    private static func scalar(in bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let first = bytes[index]
        let width = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 0
        guard width > 0, index + width <= bytes.count else { return nil }
        var decoded = UTF8()
        var iterator = bytes[index..<(index + width)].makeIterator()
        guard case let .scalarValue(scalar) = decoded.decode(&iterator) else { return nil }
        return (scalar, width)
    }

    /// The scalar that ends right before `index`.
    private static func scalar(before index: Int, in bytes: [UInt8]) -> Unicode.Scalar? {
        var start = index - 1
        while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
        guard start >= 0, index > 0 else { return nil }
        return scalar(in: bytes, at: start)?.0
    }

    /// The word before the dot is one letter: «т.», «д.», «А.».
    private static func isAbbreviation(_ bytes: [UInt8], dot: Int) -> Bool {
        guard let letter = scalar(before: dot, in: bytes), letter.properties.isAlphabetic else { return false }
        let width = String(Character(letter)).utf8.count
        guard dot - width > 0, let before = scalar(before: dot - width, in: bytes) else { return true }
        return !before.properties.isAlphabetic
    }
}

/// The scripts the bench types.
public enum LetterScript: Hashable, Sendable {
    case cyrillic, latin
    /// A letter of another script: no layout of the bench types it.
    case other

    /// The script of a letter; nil for what is not a letter.
    public static func of(_ character: Character) -> LetterScript? {
        guard character.isLetter, let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x0400...0x052F: return .cyrillic
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        default: return .other
        }
    }
}
