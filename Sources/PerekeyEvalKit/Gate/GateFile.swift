// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `eval/gates.json`: the bars of the quality step (docs/eval.md, «Планки»).
/// Reading is strict, like the case format: an unknown field, metric or
/// version is an error, not something to skip.
public struct GateFile: Hashable, Sendable, Codable {
    public static let version = 1

    /// A bar. `suite` and `profile` are names, or patterns with `*`; a rule names one of them.
    public struct Rule: Hashable, Sendable, Codable {
        public var suite: String?
        public var profile: String?
        /// Only cases whose `meta.status` is this (the incidents).
        public var status: String?
        public var metric: String
        /// `down` (the default): the count must not grow. `up`: it must not fall.
        public var direction: String?

        public init(suite: String? = nil, profile: String? = nil, status: String? = nil, metric: String,
                    direction: String? = nil)
        {
            self.suite = suite
            self.profile = profile
            self.status = status
            self.metric = metric
            self.direction = direction
        }

        public var scope: String { suite ?? "profile:\(profile ?? "?")" }
        public var up: Bool { direction == "up" }
    }

    /// A deliberate exception, added by the pull request that caused the growth.
    public struct Accepted: Hashable, Sendable, Codable {
        public var metric: String
        /// A suite name, or `profile:<name>`; `*` matches any run of characters.
        public var scope: String
        public var reason: String
        public var pr: Int
    }

    /// A goal with a number: printed, never a bar.
    public struct Target: Hashable, Sendable, Codable {
        public var metric: String
        public var scope: String
        public var value: Double
        public var note: String?
    }

    public var version: Int
    public var zero: [Rule]
    public var noWorse: [Rule]
    public var accepted: [Accepted]
    public var targets: [Target]

    public init(version: Int = GateFile.version, zero: [Rule] = [], noWorse: [Rule] = [], accepted: [Accepted] = [],
                targets: [Target] = [])
    {
        self.version = version
        self.zero = zero
        self.noWorse = noWorse
        self.accepted = accepted
        self.targets = targets
    }

    public static func read(_ path: String) throws -> GateFile {
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError.input("no such file: \(path)") }
        return try parse(data, file: path)
    }

    static func parse(_ data: Data, file: String) throws -> GateFile {
        let known: [String: Set<String>] = [
            "": ["version", "zero", "noWorse", "accepted", "targets"],
            "rule": ["suite", "profile", "status", "metric", "direction"],
            "accepted": ["metric", "scope", "reason", "pr"],
            "target": ["metric", "scope", "value", "note"],
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EvalError.input("\(file): not a JSON object")
        }
        func check(_ keys: Dictionary<String, Any>.Keys, _ kind: String, _ where: String) throws {
            for key in keys.sorted() where !known[kind]!.contains(key) {
                throw EvalError.input("\(file): unknown field \(key) in \(`where`)")
            }
        }
        try check(object.keys, "", "the file")
        for (list, kind) in [("zero", "rule"), ("noWorse", "rule"), ("accepted", "accepted"), ("targets", "target")] {
            for (index, entry) in ((object[list] as? [Any]) ?? []).enumerated() {
                guard let fields = entry as? [String: Any] else { throw EvalError.input("\(file): \(list)[\(index)] is not an object") }
                try check(fields.keys, kind, "\(list)[\(index)]")
            }
        }
        let gates: GateFile
        do { gates = try JSONDecoder().decode(GateFile.self, from: data) } catch {
            throw EvalError.input("\(file): \(error)")
        }
        guard gates.version == version else { throw EvalError.input("\(file): version \(gates.version), this is \(version)") }
        for (list, rules) in [("zero", gates.zero), ("noWorse", gates.noWorse)] {
            for rule in rules {
                guard (rule.suite == nil) != (rule.profile == nil) else {
                    throw EvalError.input("\(file): a rule of \(list) names a suite or a profile, one of them: \(rule)")
                }
                guard GateMetric.names.contains(rule.metric) else {
                    throw EvalError.input("\(file): unknown metric \(rule.metric); known: \(GateMetric.names.joined(separator: ", "))")
                }
                guard [nil, "down", "up"].contains(rule.direction) else {
                    throw EvalError.input("\(file): direction is up or down, not \(rule.direction ?? "")")
                }
                if list == "zero", rule.up || rule.profile != nil {
                    throw EvalError.input("\(file): a bar of zero counts events of a suite: \(rule)")
                }
            }
        }
        for entry in gates.accepted where !GateMetric.names.contains(entry.metric) {
            throw EvalError.input("\(file): accepted: unknown metric \(entry.metric)")
        }
        return gates
    }
}

/// The counts a bar reads: names of `eval/gates.json` over `Metrics`.
public enum GateMetric {
    /// Name → the count of a group of cases. `harm.incidents` is the events of harm
    /// (tokens in a row count once), not the suite `incidents`.
    static let counts: [String: KeyPath<Metrics, Int> & Sendable] = [
        "fail": \.fail, "exact": \.exact, "fixed": \.fixed, "harm": \.harm, "harm.incidents": \.harmEvents,
        "silent": \.silent, "botched": \.botched, "disputed": \.disputed, "miss": \.miss,
        "miss.layout": \.missLayout, "spill": \.spill, "checksFailed": \.checksFailed,
    ]

    public static var names: [String] { counts.keys.sorted() }

    /// Whether a name matches a pattern in which `*` stands for any run of characters.
    public static func matches(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == name }
        guard name.hasPrefix(parts[0]), name.hasSuffix(parts[parts.count - 1]), name.count >= parts[0].count + parts[parts.count - 1].count
        else { return false }
        var rest = Substring(name.dropFirst(parts[0].count).dropLast(parts[parts.count - 1].count))
        for middle in parts.dropFirst().dropLast() where !middle.isEmpty {
            guard let found = rest.range(of: middle) else { return false }
            rest = rest[found.upperBound...]
        }
        return true
    }
}
