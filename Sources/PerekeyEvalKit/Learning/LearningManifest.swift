// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// A set `learning.*` (docs/eval.md, «Обучение»): a person with a personal
/// vocabulary who types for a number of days, and how they answer Perekey.
/// `eval/learning/<name>.learning.json`. Strict: an unknown key is an error.
public struct LearningManifest: Hashable, Sendable, Codable {
    /// What the person answers to «Больше не менять “слово”?».
    public enum Answer: String, Hashable, Sendable, Codable, CaseIterable {
        /// «Везде».
        case everywhere
        /// «Только здесь».
        case here
        /// The question is not answered: the word stays a candidate.
        case never
    }

    public var name: String
    public var about: String?
    /// Exactly two layouts, in system order: a word and its other reading.
    public var layouts: [String]
    /// The vocabulary file, relative to the manifest: `word<TAB>layout`.
    public var vocabulary: String
    /// A preset of `EvalSettings`; `default` when absent.
    public var settings: String?
    /// The apps the person types in, a message at a time, by turns of the seed.
    public var apps: [String]?
    public var days: Int
    public var messagesPerDay: Int
    /// Tokens of a message, each a word of the vocabulary. 1 when absent.
    public var wordsPerMessage: Int?
    /// The exponent of Zipf's law over the vocabulary in file order.
    public var zipf: Double
    /// Of the occurrences, the share in which the person means the other
    /// reading: the same keys, but the switch is right.
    public var meantOther: Double
    public var backspaceShare: Double
    public var accident: Double
    public var accidentContinues: Double?
    public var accidentRetypes: Double?
    public var answer: Answer
    /// Seconds from the end of a token to the answer (`Typist.Reactor.Options.reaction`); 0.5 when absent.
    public var reaction: Double?
    public var seed: UInt64

    public static let defaultApp = "com.apple.TextEdit"

    public var effectiveApps: [String] { apps?.isEmpty == false ? apps! : [Self.defaultApp] }
    public var effectiveWordsPerMessage: Int { wordsPerMessage ?? 1 }
    public var effectiveSettings: String { settings ?? EvalSettings.defaultPreset }

    public var reactorOptions: Typist.Reactor.Options {
        var options = Typist.Reactor.Options()
        options.backspaceShare = backspaceShare
        options.accident = accident
        options.accidentContinues = accidentContinues ?? 0
        options.accidentRetypes = accidentRetypes ?? 0
        if let reaction { options.reaction = reaction }
        return options
    }

    /// The shares a sweep may change, as `manifest.<name>`.
    static let overridable: Set<String> = [
        "manifest.meantOther", "manifest.backspaceShare", "manifest.accident", "manifest.accidentContinues",
        "manifest.accidentRetypes", "manifest.zipf",
    ]

    /// The manifest with one of `overridable` set; the result is checked again.
    func overriding(_ name: String, _ value: Double) throws -> LearningManifest {
        var copy = self
        switch name {
        case "manifest.meantOther": copy.meantOther = value
        case "manifest.backspaceShare": copy.backspaceShare = value
        case "manifest.accident": copy.accident = value
        case "manifest.accidentContinues": copy.accidentContinues = value
        case "manifest.accidentRetypes": copy.accidentRetypes = value
        case "manifest.zipf": copy.zipf = value
        default: throw EvalError.input("\(self.name): \(name) cannot be set from a grid")
        }
        try copy.validate(label: "\(self.name) with \(name)=\(value)")
        return copy
    }

    private static let keys: Set<String> = [
        "name", "about", "layouts", "vocabulary", "settings", "apps", "days", "messagesPerDay", "wordsPerMessage",
        "zipf", "meantOther", "backspaceShare", "accident", "accidentContinues", "accidentRetypes", "answer", "reaction", "seed",
    ]

    /// Reads a manifest. Unknown keys, a share outside [0, 1] and a layout
    /// count other than two are errors.
    public static func read(file: String) throws -> LearningManifest {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: file)) } catch {
            throw EvalError.input("cannot read \(file)")
        }
        return try parse(data, label: file)
    }

    public static func parse(_ data: Data, label: String) throws -> LearningManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EvalError.input("\(label): not a JSON object")
        }
        let unknown = Set(object.keys).subtracting(keys)
        if let name = unknown.sorted().first { throw EvalError.input("\(label): unknown key \(name)") }
        let manifest: LearningManifest
        do { manifest = try JSONDecoder().decode(LearningManifest.self, from: data) } catch {
            throw EvalError.input("\(label): \(error)")
        }
        try manifest.validate(label: label)
        return manifest
    }

    func validate(label: String) throws {
        guard name.hasPrefix("learning.") else { throw EvalError.input("\(label): name must start with learning.") }
        guard layouts.count == 2 else { throw EvalError.input("\(label): layouts must name exactly two layouts") }
        guard days > 0, messagesPerDay > 0, effectiveWordsPerMessage > 0 else {
            throw EvalError.input("\(label): days, messagesPerDay and wordsPerMessage must be positive")
        }
        guard zipf >= 0 else { throw EvalError.input("\(label): zipf must not be negative") }
        let shares = ["meantOther": meantOther, "backspaceShare": backspaceShare, "accident": accident,
                      "accidentContinues": accidentContinues ?? 0, "accidentRetypes": accidentRetypes ?? 0]
        for (key, value) in shares.sorted(by: { $0.key < $1.key }) where !(0...1).contains(value) {
            throw EvalError.input("\(label): \(key) is a share, 0…1")
        }
        guard (accidentContinues ?? 0) + (accidentRetypes ?? 0) <= 1 else {
            throw EvalError.input("\(label): accidentContinues and accidentRetypes together are a share, at most 1")
        }
        guard (reaction ?? 0.5) >= 0 else { throw EvalError.input("\(label): reaction must not be negative") }
        guard EvalSettings.preset(effectiveSettings) != nil else {
            throw EvalError.input("\(label): unknown settings preset \(effectiveSettings)")
        }
    }
}

/// The words of a personal vocabulary, in the order of their Zipf ranks.
public struct LearningVocabulary: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        /// The word as the person means it when they want it left.
        public var word: String
        /// The layout the person writes it in.
        public var layout: String
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// `word<TAB>layout`, one per line; `#` starts a comment line. A word
    /// twice, a missing layout or an empty list are errors.
    public static func read(file: String) throws -> LearningVocabulary {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            throw EvalError.input("cannot read \(file)")
        }
        return try parse(text, label: file)
    }

    public static func parse(_ text: String, label: String) throws -> LearningVocabulary {
        var entries: [Entry] = []
        var seen: Set<String> = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw EvalError.input("\(label):\(index + 1): expected word<TAB>layout")
            }
            let word = String(fields[0])
            guard seen.insert(word).inserted else { throw EvalError.input("\(label):\(index + 1): \(word) twice") }
            entries.append(Entry(word: word, layout: String(fields[1])))
        }
        guard !entries.isEmpty else { throw EvalError.input("\(label): no words") }
        return LearningVocabulary(entries: entries)
    }
}
