// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `perekey-eval cases build` (docs/eval.md, «Команды»):
///
///     perekey-eval cases build [--suites <dir>] [--cache <dir>] [--tier ci|full] [--out <dir>]
///                              [--only <suite,...>] [--epoch <n>] [--layouts <dir>]
///
/// Writes `<out>/<suite>.jsonl` for each manifest and `<out>/build.json`
/// with the counts and the SHA-256 of every file. Nothing in `build.json`
/// or on the screen is a word of a case: the build is the same on any day,
/// and the report is safe to show.
extension EvalCommands {
    struct BuildSettings {
        var suites: String
        var cache: String
        var tier: SuiteManifest.Tier
        var epoch: Int?
        var only: Set<String>?

        init(_ parsed: Arguments) throws {
            suites = parsed.value("--suites") ?? "eval/suites"
            cache = parsed.value("--cache") ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"]
                ?? ".build/data-cache"
            guard let tier = SuiteManifest.Tier(rawValue: parsed.value("--tier") ?? "ci") else {
                throw EvalError.input("--tier ci|full")
            }
            self.tier = tier
            if let text = parsed.value("--epoch") {
                guard let epoch = Int(text), epoch >= 1 else { throw EvalError.input("--epoch <n>, n >= 1") }
                self.epoch = epoch
            }
            only = parsed.value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        }

        /// The manifests after `--only` and `--epoch`.
        func manifests() throws -> [SuiteManifest] {
            var manifests = try SuiteManifestFiles.read(directory: suites)
            if let only {
                let known = Set(manifests.map(\.suite))
                if let unknown = only.subtracting(known).sorted().first { throw EvalError.input("no suite \(unknown)") }
                manifests = manifests.filter { only.contains($0.suite) }
            }
            if let epoch {
                for index in manifests.indices { manifests[index].epoch = epoch }
            }
            return manifests
        }
    }

    /// One suite built: its cases as the bytes of the file, and the report.
    struct BuiltSuite {
        var report: BuildReport
        var bytes: Data
        var sha256: String
    }

    static func builtSuite(_ manifest: SuiteManifest, settings: BuildSettings, library: LayoutLibrary) throws -> BuiltSuite {
        let output = if manifest.correction != nil {
            try CorrectionBuilder(manifest: manifest, library: library).build(tier: settings.tier, cache: settings.cache)
        } else {
            try SuiteBuilder(manifest: manifest, library: library).build(tier: settings.tier, cache: settings.cache)
        }
        let bytes = Data(try CaseCodec.write(output.cases).utf8)
        return BuiltSuite(report: output.report, bytes: bytes, sha256: Runner.sha256(bytes))
    }

    static func build(_ parsed: Arguments) throws -> Int32 {
        let settings = try BuildSettings(parsed)
        let library = try parsed.library()
        let out = parsed.value("--out") ?? ".build/quality/cases/\(settings.tier.rawValue)"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var entries: [BuildSummary.Entry] = []
        for manifest in try settings.manifests() {
            let built = try builtSuite(manifest, settings: settings, library: library)
            let path = (out as NSString).appendingPathComponent("\(manifest.suite).jsonl")
            try built.bytes.write(to: URL(fileURLWithPath: path))
            entries.append(.init(report: built.report, sha256: built.sha256, bytes: built.bytes.count))
            print(Console.buildLine(built.report, sha256: built.sha256))
        }
        let summary = BuildSummary(tier: settings.tier.rawValue, suites: entries)
        let json = try CaseCodec.json(summary) + "\n"
        try json.write(toFile: (out as NSString).appendingPathComponent("build.json"), atomically: true, encoding: .utf8)
        return 0
    }
}

/// `build.json`: the reports of a build and the hash of every file.
struct BuildSummary: Codable {
    struct Entry: Codable {
        var report: BuildReport
        var sha256: String
        var bytes: Int
    }

    var tier: String
    var suites: [Entry]
}

extension Console {
    /// One line per built suite: counts, no words.
    static func buildLine(_ report: BuildReport, sha256: String) -> String {
        var line = "\(report.suite)  units \(report.units)  pooled \(report.pooled)  sha256 \(sha256.prefix(16))"
        for name in SuiteManifest.scenarioNames + SuiteManifest.correctionScenarioNames {
            guard let stats = report.scenarios[name] else { continue }
            line += "\n  \(name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + String(format: "%7d cases %8d tokens  dev %6d  test %6d", stats.cases, stats.tokens, stats.dev, stats.test)
                + (stats.errors.map { "  slips \($0)" } ?? "")
                + (stats.shortfall > 0 ? "  short \(stats.shortfall)" : "")
        }
        return line
    }
}
