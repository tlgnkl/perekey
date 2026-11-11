// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// A run of one script inside a token, with the marks that go with it.
/// «USB-порт» is two: `USB-` and `порт`.
struct Segment: Hashable {
    var text: String
    /// Nil for a token with no letter at all: it aims at the layout of the token before it.
    var script: LetterScript?
}

/// A token of a unit, cut into segments.
struct ParsedToken: Hashable {
    var text: String
    var segments: [Segment]
    /// The token was inside an inline `<code>`.
    var code: Bool

    var hasLetters: Bool { segments.contains { $0.script != nil } }
    var scripts: [LetterScript] { segments.compactMap(\.script) }
    var isMixed: Bool { Set(scripts).count > 1 }
}

/// Why a unit did not become a case. The raw value is the name in the build
/// report.
enum Drop: String, CaseIterable, Hashable, Error {
    case tooShort, tooLong
    /// The sentence has no letter.
    case noLetters
    /// The manifest asks for a script the sentence lacks.
    case missingScript
    /// A letter of a script the bench has no layout for.
    case otherScript
    /// A character a layout of the set does not type without ⌥ and Caps Lock.
    case unprintable
    case duplicate
    /// A named entity the reader does not know (`&foo;`) is left in the text: the sentence is not what the person wrote.
    case entity
    /// `stuck` and `clean.toggle` need both scripts in the text.
    case singleScript
    /// There is no sentence of the other language to warm up with.
    case noWarmup
    /// Null got a token wrong in a `clean` scenario: the case would blame the system for the typist.
    case nullWrongInClean
    /// A correction suite: the sentence has both scripts. The suites of corrections type one layout.
    case mixedScript
    /// A correction suite: nothing in the sentence for the edit to change.
    case noTarget
    /// `typos.synth`: the dice chose a slip the word has no place for.
    case noTypo
    /// A correction suite: the edit left no token that Null gets wrong, or a character the layout does not type.
    case nullRight
}

/// What the layouts of one set say about a language: the Latin layout, the
/// Cyrillic one and the language code of that.
struct LayoutSet {
    var latin: String
    var cyrillic: String
    /// The language of Cyrillic letters: `ru`, `uk`, `be`, `kk`.
    var language: String

    init(names: [String], library: LayoutLibrary) throws {
        var latin: String?
        var cyrillic: String?
        var language: String?
        for name in names {
            guard let map = library[name] else { throw EvalError.input("unknown layout \(name)") }
            if map.language == "en" {
                guard latin == nil else { throw EvalError.input("layout set \(names): two Latin layouts") }
                latin = name
            } else {
                guard cyrillic == nil, let code = map.language else {
                    throw EvalError.input("layout set \(names): needs one Latin and one Cyrillic layout")
                }
                cyrillic = name
                language = code
            }
        }
        guard let latin, let cyrillic, let language else {
            throw EvalError.input("layout set \(names): needs one Latin and one Cyrillic layout")
        }
        self.latin = latin
        self.cyrillic = cyrillic
        self.language = language
    }

    var names: [String] { [latin, cyrillic] }

    func layout(for script: LetterScript) -> String? {
        switch script {
        case .latin: latin
        case .cyrillic: cyrillic
        case .other: nil
        }
    }

    func code(for script: LetterScript?) -> String {
        switch script {
        case .latin: "en"
        case .cyrillic: language
        case .other, nil: "-"
        }
    }

    /// The other layout of the set.
    func other(than name: String) -> String { name == latin ? cyrillic : latin }
}

/// A unit read as tokens, aimed at the layouts of a set.
struct ParsedUnit {
    var tokens: [ParsedToken]
    var set: LayoutSet

    /// The layout the fingers aim at for each segment, token after token.
    /// A token with no letter aims where the token before it did; the first
    /// ones where the first token with letters does.
    var aims: [[String]] {
        var first: String?
        for token in tokens {
            if let script = token.scripts.first, let layout = set.layout(for: script) {
                first = layout
                break
            }
        }
        var previous = first ?? set.latin
        var result: [[String]] = []
        for token in tokens {
            var row: [String] = []
            for segment in token.segments {
                if let script = segment.script, let layout = set.layout(for: script) { previous = layout }
                row.append(previous)
            }
            result.append(row)
        }
        return result
    }

    /// The scripts of the letters of the whole unit.
    var scripts: Set<LetterScript> { Set(tokens.flatMap(\.scripts)) }

    /// The script of the first letter: the language the unit starts in.
    var firstScript: LetterScript? { tokens.lazy.compactMap { $0.scripts.first }.first }
}

enum UnitParser {
    /// Reads the text of a unit into tokens. Applies the manifest's `transform`
    /// and `normalize`. Returns the reason when the unit is out: the length
    /// and script filter of the manifest, a letter no layout types, a
    /// character the set cannot type.
    static func parse(_ text: String, manifest: SuiteManifest, set: LayoutSet, library: LayoutLibrary,
                      filter: SuiteManifest.Filter? = nil) -> Result<ParsedUnit, Drop>
    {
        // Most sentences of a big source miss the length filter; count their
        // tokens on scalars before the slow work on characters. The count only
        // rejects what no change of the text could save: the changes below
        // never add a token, and `stripPunctuation` may remove one.
        let limits = filter ?? manifest.filter
        let quick = quickTokenCount(text)
        if quick < (limits?.minTokens ?? 1) { return .failure(.tooShort) }
        if let maximum = limits?.maxTokens, quick > maximum, !(manifest.transform ?? []).contains(.stripPunctuation) {
            return .failure(.tooLong)
        }
        if hasUnknownEntity(text) { return .failure(.entity) }
        var text = text
        if manifest.effectiveNormalize == .keyboard { text = keyboard(text) }
        for step in manifest.transform ?? [] {
            switch step {
            case .lowercase: text = text.lowercased()
            case .stripPunctuation: text = stripPunctuation(text)
            }
        }
        return parse(text, filter: filter ?? manifest.filter, set: set, library: library)
    }

    static func parse(_ text: String, filter: SuiteManifest.Filter?, set: LayoutSet, library: LayoutLibrary)
        -> Result<ParsedUnit, Drop>
    {
        let tokens = tokens(of: text)
        if tokens.count < (filter?.minTokens ?? 1) { return .failure(.tooShort) }
        if let maximum = filter?.maxTokens, tokens.count > maximum { return .failure(.tooLong) }
        let unit = ParsedUnit(tokens: tokens, set: set)
        let scripts = unit.scripts
        if scripts.isEmpty { return .failure(.noLetters) }
        if scripts.contains(.other) { return .failure(.otherScript) }
        for required in filter?.requireScripts ?? [] {
            let script: LetterScript = required == .cyrillic ? .cyrillic : .latin
            if !scripts.contains(script) { return .failure(.missingScript) }
        }
        let aims = unit.aims
        for (token, row) in zip(tokens, aims) {
            for (segment, name) in zip(token.segments, row) {
                guard let map = library[name] else { return .failure(.unprintable) }
                for character in segment.text where LayoutLibrary.printableStroke(character, in: map) == nil {
                    return .failure(.unprintable)
                }
            }
        }
        return .success(unit)
    }

    /// `&name;` or `&#…;` left in a sentence: `SourceText` reads the entities it knows (the five of XML, a few
    /// of HTML, the numeric ones), so what remains is one it does not.
    static func hasUnknownEntity(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "&") else {
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, end - index <= 10,
                  bytes[end] == UInt8(ascii: "#") || (0x30...0x39).contains(bytes[end]) || (0x41...0x5A).contains(bytes[end])
                  || (0x61...0x7A).contains(bytes[end])
            {
                end += 1
            }
            if end > index + 1, end < bytes.count, bytes[end] == UInt8(ascii: ";") { return true }
            index += 1
        }
        return false
    }

    /// Runs of non-whitespace scalars, the code marks not counted as text.
    static func quickTokenCount(_ text: String) -> Int {
        var count = 0
        var inToken = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                inToken = false
            } else if scalar == "\u{E000}" || scalar == "\u{E001}" {
                continue
            } else if !inToken {
                inToken = true
                count += 1
            }
        }
        return count
    }

    /// The characters of a unit that the layouts of the set do not type, for
    /// the build report. Runs the same steps as `parse` up to the check.
    static func unprintableCharacters(_ text: String, manifest: SuiteManifest, set: LayoutSet, library: LayoutLibrary) -> [Character] {
        var text = text
        if manifest.effectiveNormalize == .keyboard { text = keyboard(text) }
        for step in manifest.transform ?? [] {
            switch step {
            case .lowercase: text = text.lowercased()
            case .stripPunctuation: text = stripPunctuation(text)
            }
        }
        let unit = ParsedUnit(tokens: tokens(of: text), set: set)
        var found: [Character] = []
        for (token, row) in zip(unit.tokens, unit.aims) {
            for (segment, name) in zip(token.segments, row) {
                guard let map = library[name] else { continue }
                found += segment.text.filter { LayoutLibrary.printableStroke($0, in: map) == nil }
            }
        }
        return found
    }

    /// The tokens of a text; the code marks are read and taken off.
    static func tokens(of text: String) -> [ParsedToken] {
        var tokens: [ParsedToken] = []
        var current = ""
        var code = false
        var inCode = false
        func finish() {
            guard !current.isEmpty else { return }
            tokens.append(ParsedToken(text: current, segments: segments(of: current), code: code))
            current = ""
            code = false
        }
        for character in text {
            if character == SourceText.codeOpen {
                inCode = true
            } else if character == SourceText.codeClose {
                inCode = false
            } else if character.isWhitespace {
                finish()
            } else {
                current.append(character)
                if inCode { code = true }
            }
        }
        finish()
        return tokens
    }

    /// Runs of one script. Marks and digits join the run before them; the
    /// ones in front of the first letter join the first run.
    static func segments(of token: String) -> [Segment] {
        var runs: [(text: String, script: LetterScript?)] = []
        var leading = ""
        for character in token {
            if let script = LetterScript.of(character) {
                if let last = runs.last, last.script == script {
                    runs[runs.count - 1].text.append(character)
                } else {
                    runs.append((leading + String(character), script))
                    leading = ""
                }
            } else if runs.isEmpty {
                leading.append(character)
            } else {
                runs[runs.count - 1].text.append(character)
            }
        }
        if runs.isEmpty { return [Segment(text: leading, script: nil)] }
        return runs.map { Segment(text: $0.text, script: $0.script) }
    }

    // MARK: - Text changes

    /// Typographic marks to the keys that type them (`SuiteManifest.Normalize`).
    static func keyboard(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "«", "»", "“", "”", "„", "‟": result.append("\"")
            case "‘", "’", "ʼ", "ʻ": result.append("'")
            case "—", "–", "‒", "−", "‑": result.append("-")
            case "…": result += "..."
            case "\u{00A0}", "\u{202F}", "\u{2009}": result.append(" ")
            default: result.append(character)
            }
        }
        return result
    }

    /// Without punctuation, except an apostrophe or a hyphen between letters.
    static func stripPunctuation(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let isMark = character.isPunctuation || character.isSymbol
            guard isMark else {
                result.append(character)
                continue
            }
            let inside = index > 0 && index + 1 < characters.count
                && characters[index - 1].isLetter && characters[index + 1].isLetter
            if inside, character == "'" || character == "-" { result.append(character) }
        }
        return result
    }
}
