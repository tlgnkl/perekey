// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// `--options <json>`: fields of `Classifier.Options` over the defaults, for
/// tuning and for the mutants of the self-check. `Options` is not `Codable`,
/// and the bench does not make it so: this table names every field, and a
/// test fails when the core adds one the table does not know.
public enum ClassifierOptions {
    typealias Setter = @Sendable (inout Classifier.Options, Double) throws -> Void

    static let table: [String: Setter] = [
        "threshold": { $0.threshold = $1 },
        "readingMargin": { $0.readingMargin = $1 },
        "unknownWordExtra": { $0.unknownWordExtra = $1 },
        "noiseCost": { $0.noiseCost = $1 },
        "unknownNoiseCost": { $0.unknownNoiseCost = $1 },
        "openerBonus": { $0.openerBonus = $1 },
        "dictionaryBonus": { $0.dictionaryBonus = $1 },
        "rankBonus": { $0.rankBonus = $1 },
        "knownRank": { $0.knownRank = try rank($1, "knownRank") },
        "mixedCaseRank": { $0.mixedCaseRank = try rank($1, "mixedCaseRank") },
        "contextBonus": { $0.contextBonus = $1 },
        "contextDecay": { $0.contextDecay = $1 },
        "priorLimit": { $0.priorLimit = $1 },
        "priorScale": { $0.priorScale = $1 },
        "shortWordRank": { $0.shortWordRank = try rank($1, "shortWordRank") },
        "personalRank": { $0.personalRank = try rank($1, "personalRank") },
        "personalNoiseCost": { $0.personalNoiseCost = $1 },
        "wordContextLimit": { $0.wordContextLimit = $1 },
    ]

    /// The names the table knows.
    public static var names: [String] { table.keys.sorted() }

    /// The defaults with the fields of a JSON object: `{"threshold": 12}`.
    /// An unknown name or a value that is not a number is an error.
    public static func parse(_ json: String) throws -> Classifier.Options {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw EvalError.input("--options: not a JSON object: \(json)")
        }
        var options = Classifier.Options()
        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let set = table[name] else {
                throw EvalError.input("--options: Classifier.Options has no field \(name); known: \(names.joined(separator: ", "))")
            }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw EvalError.input("--options: \(name) is not a number")
            }
            try set(&options, number.doubleValue)
        }
        return options
    }

    private static func rank(_ value: Double, _ name: String) throws -> UInt8 {
        guard value >= 0, value <= 255, value == value.rounded() else {
            throw EvalError.input("--options: \(name) is a rank, a whole number 0…255")
        }
        return UInt8(value)
    }
}
