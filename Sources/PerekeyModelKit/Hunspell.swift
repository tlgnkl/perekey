// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Expands a Hunspell dictionary (`.dic` + `.aff`) into word forms.
///
/// Covers what ru_RU (Lebedev) and SCOWL en_US need: single-character flags,
/// `SFX` and `PFX` rules with strip, add and a condition, cross product of a
/// prefix with a suffix. Compounding, `FLAG long/num`, `ICONV`, `REP` and
/// morphological fields are ignored.
public struct Hunspell {
    public struct Rule {
        /// What to remove from the stem before adding; "0" in the file.
        var strip: String
        var add: String
        /// Flags carried by the added affix ("ive/N" is unused by our files).
        var condition: Condition
    }

    public struct AffixClass {
        var crossProduct: Bool
        var rules: [Rule]
    }

    /// A Hunspell condition: a sequence of literal characters and character
    /// classes, matched at the end (suffix) or start (prefix) of the stem.
    public struct Condition {
        enum Part {
            case any
            case literal(Character)
            case set(Set<Character>, negated: Bool)
        }

        let parts: [Part]

        init(_ text: Substring) {
            var parts: [Part] = []
            var index = text.startIndex
            while index < text.endIndex {
                let character = text[index]
                if character == "." {
                    parts.append(.any)
                    index = text.index(after: index)
                } else if character == "[" {
                    guard let close = text[index...].firstIndex(of: "]") else { break }
                    var members = text[text.index(after: index)..<close]
                    var negated = false
                    if members.first == "^" {
                        negated = true
                        members = members.dropFirst()
                    }
                    parts.append(.set(Set(members), negated: negated))
                    index = text.index(after: close)
                } else {
                    parts.append(.literal(character))
                    index = text.index(after: index)
                }
            }
            self.parts = parts
        }

        func matches(_ characters: ArraySlice<Character>) -> Bool {
            guard characters.count >= parts.count else { return false }
            for (part, character) in zip(parts, characters) {
                switch part {
                case .any: continue
                case let .literal(expected): if character != expected { return false }
                case let .set(members, negated): if members.contains(character) == negated { return false }
                }
            }
            return true
        }
    }

    public var suffixes: [Character: AffixClass] = [:]
    public var prefixes: [Character: AffixClass] = [:]

    public init(affix text: String) {
        var current: (isSuffix: Bool, flag: Character)?
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, fields[0] == "SFX" || fields[0] == "PFX", let flag = fields[1].first else {
                continue
            }
            let isSuffix = fields[0] == "SFX"
            if current == nil || current! != (isSuffix, flag) {
                // Header: SFX flag Y/N count
                current = (isSuffix, flag)
                let affixClass = AffixClass(crossProduct: fields[2] == "Y", rules: [])
                if isSuffix { suffixes[flag] = affixClass } else { prefixes[flag] = affixClass }
                continue
            }
            // Rule: SFX flag strip add [condition] — the condition may be missing
            // in some files and the "add" may carry "/flags" we ignore.
            let strip = fields[2] == "0" ? "" : String(fields[2])
            let add = fields[3] == "0" ? "" : String(fields[3].split(separator: "/").first ?? "")
            let condition = Condition(fields.count >= 5 ? fields[4] : ".")
            let rule = Rule(strip: strip, add: add, condition: condition)
            if isSuffix { suffixes[flag]!.rules.append(rule) } else { prefixes[flag]!.rules.append(rule) }
        }
    }

    /// Calls `emit` for the stem and every form the flags produce. Forms can
    /// repeat; the caller deduplicates.
    public func expand(_ stem: String, flags: Substring, emit: (String) -> Void) {
        emit(stem)
        let characters = Array(stem)
        var suffixed: [String] = []
        for flag in flags {
            if let affixClass = suffixes[flag] {
                for rule in affixClass.rules {
                    guard let form = apply(rule, toEnd: characters) else { continue }
                    emit(form)
                    if affixClass.crossProduct { suffixed.append(form) }
                }
            }
        }
        for flag in flags {
            guard let affixClass = prefixes[flag] else { continue }
            for rule in affixClass.rules {
                if let form = apply(rule, toStart: characters) { emit(form) }
                guard affixClass.crossProduct else { continue }
                for form in suffixed {
                    if let combined = apply(rule, toStart: Array(form)) { emit(combined) }
                }
            }
        }
    }

    private func apply(_ rule: Rule, toEnd stem: [Character]) -> String? {
        guard stem.count >= rule.strip.count, rule.condition.matches(stem.suffix(rule.condition.parts.count)) else {
            return nil
        }
        let base = stem.dropLast(rule.strip.count)
        guard String(stem.suffix(rule.strip.count)) == rule.strip else { return nil }
        return String(base) + rule.add
    }

    private func apply(_ rule: Rule, toStart stem: [Character]) -> String? {
        guard stem.count >= rule.strip.count, rule.condition.matches(stem.prefix(rule.condition.parts.count)) else {
            return nil
        }
        guard String(stem.prefix(rule.strip.count)) == rule.strip else { return nil }
        return rule.add + String(stem.dropFirst(rule.strip.count))
    }

    /// Reads a `.dic` file: the first line is the count, then `word/FLAGS`
    /// with optional morphological fields after a tab.
    public static func entries(dic text: String) -> [(stem: String, flags: Substring)] {
        var entries: [(String, Substring)] = []
        for line in text.split(separator: "\n").dropFirst() {
            let record = line.split(separator: "\t", maxSplits: 1).first ?? line
            guard !record.isEmpty, record.first != "#" else { continue }
            let parts = record.split(separator: "/", maxSplits: 1)
            let stem = String(parts[0]).trimmingCharacters(in: .whitespaces)
            entries.append((stem, parts.count > 1 ? parts[1] : ""))
        }
        return entries
    }
}
