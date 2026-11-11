// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A suite's manifest, `eval/suites/<name>.suite.json` (docs/eval.md,
/// «Наборы»). Reading is strict, like the case format: an unknown field or
/// value is an error, not something to skip.
public struct SuiteManifest: Hashable, Sendable {
    /// The scenarios a corpus suite may list, in the order they are built.
    public static let scenarioNames = ["clean.cold", "clean.warm", "slip.cold", "slip.warm", "stuck", "clean.toggle"]

    public var suite: String
    public var version: Int
    /// The number of the draw from the source; a new one takes other units.
    public var epoch: Int
    /// The seed of the draw; the order of the units comes from `seed + epoch`.
    public var seed: Int
    public var about: String
    public var reader: Reader
    /// Files of the data cache, comma-separated: `tatoeba/rus_sentences.tsv.bz2,tatoeba/eng_sentences.tsv.bz2`.
    public var source: String
    public var license: String
    public var sampling: Sampling
    /// Each set is one Latin layout and one Cyrillic one. A unit is typed on
    /// the set its reference picks by hash.
    public var layoutSets: [[String]]
    public var scenarios: [String]
    /// The preset of `env.settings`; `default` when absent.
    public var settings: String?
    public var end: End?
    public var filter: Filter?
    public var tiers: Tiers
    public var split: SplitSpec
    /// How the text is made typeable and what is cut from it before the filter.
    public var normalize: Normalize?
    public var transform: [Transform]?
    /// With several source files: take as many units from each, the number the
    /// smallest file has. `true` when absent. A small file (Tatoeba `kaz`) would
    /// otherwise run out and the rest of the suite would be the other language.
    public var balance: Bool?
    public var fold: [String]?
    public var tags: [String]?

    public enum Reader: String, Hashable, Sendable, Codable, CaseIterable {
        case tatoeba, stackexchange
    }

    public enum Sampling: String, Hashable, Sendable, Codable {
        /// Text as it is written: natural frequencies.
        case token
        /// A list of words, each once. Not built by this lane.
        case type
    }

    /// What ends the case after the last token.
    public enum End: String, Hashable, Sendable, Codable {
        case space, `return`, none
    }

    public enum Script: String, Hashable, Sendable, Codable {
        case cyrillic, latin
    }

    public struct Filter: Hashable, Sendable {
        public var minTokens: Int?
        public var maxTokens: Int?
        /// Scripts the sentence must have a letter of.
        public var requireScripts: [Script]?
    }

    /// Tokens of the measured part to take for each scenario.
    public struct Tiers: Hashable, Sendable {
        public var ci: Int
        public var full: Int

        public func tokens(_ tier: Tier) -> Int {
            switch tier {
            case .ci: ci
            case .full: full
            }
        }
    }

    public enum Tier: String, Hashable, Sendable, CaseIterable {
        case ci, full
    }

    /// The dev share of the units, in percent, and what the key is.
    public struct SplitSpec: Hashable, Sendable {
        public var dev: Int
        /// `unit`: the key of a sentence is its reference.
        public var by: String
    }

    /// Typographic marks to the keys that type them: « » “ ” „ to ", ‘ ’ ʼ to ',
    /// — – to -, … to ..., no-break space to space. Without it a Russian
    /// sentence with a dash cannot be typed on a layout without ⌥.
    public enum Normalize: String, Hashable, Sendable, Codable {
        case keyboard, none
    }

    /// A change of the sentence that makes a class of text out of it.
    public enum Transform: String, Hashable, Sendable, Codable {
        case lowercase
        /// Drops punctuation except the apostrophe and the hyphen inside a word.
        case stripPunctuation
    }

    public var effectiveSettings: String { settings ?? "default" }
    public var effectiveEnd: End { end ?? .space }
    public var effectiveNormalize: Normalize { normalize ?? .keyboard }
    public var effectiveBalance: Bool { balance ?? true }

    public var sources: [String] {
        source.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Problems of the values the decoder cannot see.
    public func problems() -> [String] {
        var problems: [String] = []
        if suite.isEmpty { problems.append("empty suite name") }
        if version != 1 { problems.append("manifest version \(version), this reader knows 1") }
        if epoch < 1 { problems.append("epoch must be at least 1") }
        if layoutSets.isEmpty { problems.append("no layout set") }
        for set in layoutSets where set.count != 2 || Set(set).count != 2 {
            problems.append("layout set \(set) must be two different layouts")
        }
        if scenarios.isEmpty { problems.append("no scenarios") }
        for name in scenarios where !Self.scenarioNames.contains(name) { problems.append("unknown scenario \(name)") }
        if Set(scenarios).count != scenarios.count { problems.append("a scenario is listed twice") }
        if !(0...100).contains(split.dev) { problems.append("split.dev must be 0…100") }
        if split.by != "unit" { problems.append("split.by \(split.by): only unit is known") }
        if tiers.ci < 1 || tiers.full < tiers.ci { problems.append("tiers: 1 <= ci <= full") }
        if let minimum = filter?.minTokens, minimum < 1 { problems.append("filter.minTokens must be at least 1") }
        if let minimum = filter?.minTokens, let maximum = filter?.maxTokens, maximum < minimum {
            problems.append("filter.maxTokens is below minTokens")
        }
        if sources.isEmpty { problems.append("no source") }
        if sampling == .type { problems.append("sampling type is built by the class suites, not by this reader") }
        return problems
    }
}

extension SuiteManifest: Codable {
    private static let fields: Set<String> = [
        "suite", "version", "epoch", "seed", "about", "reader", "source", "license", "sampling", "layoutSets",
        "scenarios", "settings", "end", "filter", "tiers", "split", "normalize", "transform", "balance", "fold", "tags",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(Self.fields, in: "manifest")
        suite = try c.required(String.self, "suite")
        version = try c.required(Int.self, "version")
        epoch = try c.optional(Int.self, "epoch") ?? 1
        seed = try c.required(Int.self, "seed")
        about = try c.required(String.self, "about")
        reader = try c.required(Reader.self, "reader")
        source = try c.required(String.self, "source")
        license = try c.required(String.self, "license")
        sampling = try c.required(Sampling.self, "sampling")
        layoutSets = try c.required([[String]].self, "layoutSets")
        scenarios = try c.required([String].self, "scenarios")
        settings = try c.optional(String.self, "settings")
        end = try c.optional(End.self, "end")
        filter = try c.optional(Filter.self, "filter")
        tiers = try c.required(Tiers.self, "tiers")
        split = try c.required(SplitSpec.self, "split")
        normalize = try c.optional(Normalize.self, "normalize")
        transform = try c.optional([Transform].self, "transform")
        balance = try c.optional(Bool.self, "balance")
        fold = try c.optional([String].self, "fold")
        tags = try c.optional([String].self, "tags")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(suite, forKey: AnyKey("suite"))
        try c.encode(version, forKey: AnyKey("version"))
        try c.encode(epoch, forKey: AnyKey("epoch"))
        try c.encode(seed, forKey: AnyKey("seed"))
        try c.encode(about, forKey: AnyKey("about"))
        try c.encode(reader, forKey: AnyKey("reader"))
        try c.encode(source, forKey: AnyKey("source"))
        try c.encode(license, forKey: AnyKey("license"))
        try c.encode(sampling, forKey: AnyKey("sampling"))
        try c.encode(layoutSets, forKey: AnyKey("layoutSets"))
        try c.encode(scenarios, forKey: AnyKey("scenarios"))
        try c.encodeIfPresent(settings, forKey: AnyKey("settings"))
        try c.encodeIfPresent(end, forKey: AnyKey("end"))
        try c.encodeIfPresent(filter, forKey: AnyKey("filter"))
        try c.encode(tiers, forKey: AnyKey("tiers"))
        try c.encode(split, forKey: AnyKey("split"))
        try c.encodeIfPresent(normalize, forKey: AnyKey("normalize"))
        try c.encodeIfPresent(transform, forKey: AnyKey("transform"))
        try c.encodeIfPresent(balance, forKey: AnyKey("balance"))
        try c.encodeIfPresent(fold, forKey: AnyKey("fold"))
        try c.encodeIfPresent(tags, forKey: AnyKey("tags"))
    }
}

extension SuiteManifest.Filter: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(["minTokens", "maxTokens", "requireScripts"], in: "filter")
        minTokens = try c.optional(Int.self, "minTokens")
        maxTokens = try c.optional(Int.self, "maxTokens")
        requireScripts = try c.optional([SuiteManifest.Script].self, "requireScripts")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(minTokens, forKey: AnyKey("minTokens"))
        try c.encodeIfPresent(maxTokens, forKey: AnyKey("maxTokens"))
        try c.encodeIfPresent(requireScripts, forKey: AnyKey("requireScripts"))
    }
}

extension SuiteManifest.Tiers: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(["ci", "full"], in: "tiers")
        ci = try c.required(Int.self, "ci")
        full = try c.required(Int.self, "full")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(ci, forKey: AnyKey("ci"))
        try c.encode(full, forKey: AnyKey("full"))
    }
}

extension SuiteManifest.SplitSpec: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(["dev", "by"], in: "split")
        dev = try c.required(Int.self, "dev")
        by = try c.optional(String.self, "by") ?? "unit"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(dev, forKey: AnyKey("dev"))
        try c.encode(by, forKey: AnyKey("by"))
    }
}

public enum SuiteManifestFiles {
    /// The manifests of a directory, `*.suite.json`, in name order.
    public static func read(directory: String) throws -> [SuiteManifest] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".suite.json") }.sorted()
        return try names.map { try read(file: (directory as NSString).appendingPathComponent($0)) }
    }

    public static func read(file: String) throws -> SuiteManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let manifest: SuiteManifest
        do {
            manifest = try JSONDecoder().decode(SuiteManifest.self, from: data)
        } catch let error as DecodingError {
            throw EvalError.input("\(file): \(CaseCodec.describe(error))")
        }
        let problems = manifest.problems()
        guard problems.isEmpty else {
            throw EvalError.input("\(file): " + problems.joined(separator: "; "))
        }
        let expected = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        guard expected == "\(manifest.suite).suite" else {
            throw EvalError.input("\(file): the file is named for suite \(expected), the manifest says \(manifest.suite)")
        }
        return manifest
    }
}
