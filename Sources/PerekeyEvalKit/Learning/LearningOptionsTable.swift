// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// `--options <json>` of `perekey-eval learning`: fields of `LearningOptions`
/// (and, in the same object, of `Classifier.Options`) over the defaults.
/// `LearningOptions` is core and is not `Codable`; this table names every
/// field, and a test fails when the core adds one the table does not know.
public enum LearningOptionsTable {
    typealias Setter = @Sendable (inout LearningOptions, Double) throws -> Void

    static let table: [String: Setter] = [
        "explicitWeight": { $0.explicitWeight = try whole($1, "explicitWeight") },
        "backspaceWeight": { $0.backspaceWeight = try whole($1, "backspaceWeight") },
        "newDayBonus": { $0.newDayBonus = try whole($1, "newDayBonus") },
        "plausibleThreshold": { $0.plausibleThreshold = try whole($1, "plausibleThreshold") },
        "ordinaryThreshold": { $0.ordinaryThreshold = try whole($1, "ordinaryThreshold") },
        "frequentThreshold": { $0.frequentThreshold = try whole($1, "frequentThreshold") },
        "candidateLifetime": { $0.candidateLifetime = $1 },
        "appsForEverywhere": { $0.appsForEverywhere = try whole($1, "appsForEverywhere") },
    ]

    /// The names the table knows.
    public static var names: [String] { table.keys.sorted() }

    /// The fields of a JSON object that are `LearningOptions` over the
    /// defaults, and the rest of the object for `ClassifierOptions`.
    /// A name that neither table knows is an error; so is a value that is
    /// not a number.
    public static func parse(_ json: String) throws -> (learning: LearningOptions, classifier: Classifier.Options) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw EvalError.input("--options: not a JSON object: \(json)")
        }
        var learning = LearningOptions()
        var classifierPart: [String: Any] = [:]
        for (name, value) in object.sorted(by: { $0.key < $1.key }) {
            guard let set = table[name] else {
                classifierPart[name] = value
                continue
            }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw EvalError.input("--options: \(name) is not a number")
            }
            try set(&learning, number.doubleValue)
        }
        let rest = try JSONSerialization.data(withJSONObject: classifierPart, options: [.sortedKeys])
        do {
            return (learning, try ClassifierOptions.parse(String(decoding: rest, as: UTF8.self)))
        } catch let error as EvalError {
            throw EvalError.input("\(error); LearningOptions fields: \(names.joined(separator: ", "))")
        }
    }

    private static func whole(_ value: Double, _ name: String) throws -> Int {
        guard value >= 0, value <= 1000, value == value.rounded() else {
            throw EvalError.input("--options: \(name) is a whole number 0…1000")
        }
        return Int(value)
    }
}
