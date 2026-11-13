// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// `perekey-eval cases build` (docs/eval.md, «Команды»):
///
///     perekey-eval cases build [--suites <dir>] [--cache <dir>] [--tier ci|full] [--out <dir>]
///                              [--only <suite,...>] [--epoch <n>] [--layouts <dir>] [--lexicon <dir>] [--classes <dir>] [--skip-missing]
///
/// With `--skip-missing`, a suite whose source is not in the cache is not built: the line
/// «пропущен: нет источника X» says so, and the command goes on. Without it, a missing source is an error.
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
        /// What the class suites share: the lexicon, the dictionaries, the corpora already read.
        let classContext: ClassContext

        /// `ignoringOnly`: the self-check reads `--only` as a choice of cases, not of manifests.
        init(_ parsed: Arguments, ignoringOnly: Bool = false) throws {
            suites = parsed.value("--suites") ?? "eval/suites"
            cache = parsed.value("--cache") ?? ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"]
                ?? ".build/data-cache"
            classContext = ClassContext(cache: cache, lexiconDirectory: parsed.value("--lexicon") ?? ".build/quality",
                                        classesDirectory: parsed.value("--classes") ?? "eval/classes")
            guard let tier = SuiteManifest.Tier(rawValue: parsed.value("--tier") ?? "ci") else {
                throw EvalError.input("--tier ci|full")
            }
            self.tier = tier
            if let text = parsed.value("--epoch") {
                guard let epoch = Int(text), epoch >= 1 else { throw EvalError.input("--epoch <n>, n >= 1") }
                self.epoch = epoch
            }
            only = ignoringOnly ? nil : parsed.value("--only").map { Set($0.split(separator: ",").map(String.init)) }
        }

        /// The first file of the manifest's source that the cache lacks.
        func missingSource(of manifest: SuiteManifest) -> String? {
            manifest.sources.first {
                !FileManager.default.fileExists(atPath: (cache as NSString).appendingPathComponent($0))
            }
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

    /// Builds the suite and gives its file one case at a time to `write` (when there is one): the hash and the
    /// count of bytes come out as the cases go, and no case is kept. The bytes are those of `CaseCodec.write`.
    static func streamedSuite(_ manifest: SuiteManifest, settings: BuildSettings, library: LayoutLibrary,
                              write: ((Data) throws -> Void)? = nil) throws -> (report: BuildReport, sha256: String, bytes: Int) {
        var hasher = SHA256()
        var count = 0
        func emit(_ item: EvalCase) throws {
            try autoreleasepool {
                let data = Data((try CaseCodec.line(item) + "\n").utf8)
                hasher.update(data: data)
                count += data.count
                try write?(data)
            }
        }
        let report: BuildReport
        if manifest.reader == .class {
            report = try ClassSuiteBuilder(manifest: manifest, library: library, context: settings.classContext)
                .build(tier: settings.tier, emit: emit)
        } else if manifest.correction != nil {
            report = try CorrectionBuilder(manifest: manifest, library: library)
                .build(tier: settings.tier, cache: settings.cache, emit: emit)
        } else {
            report = try SuiteBuilder(manifest: manifest, library: library)
                .build(tier: settings.tier, cache: settings.cache, emit: emit)
        }
        return (report, hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }

    static func builtSuite(_ manifest: SuiteManifest, settings: BuildSettings, library: LayoutLibrary) throws -> BuiltSuite {
        var bytes = Data()
        let streamed = try streamedSuite(manifest, settings: settings, library: library) { bytes.append($0) }
        return BuiltSuite(report: streamed.report, bytes: bytes, sha256: streamed.sha256)
    }

    static func build(_ parsed: Arguments) throws -> Int32 {
        let settings = try BuildSettings(parsed)
        let library = try parsed.library()
        let out = parsed.value("--out") ?? ".build/quality/cases/\(settings.tier.rawValue)"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var entries: [BuildSummary.Entry] = []
        for manifest in try settings.manifests() {
            if parsed.flag("--skip-missing"), let missing = settings.missingSource(of: manifest) {
                print("\(manifest.suite)  пропущен: нет источника \(missing)")
                continue
            }
            let path = (out as NSString).appendingPathComponent("\(manifest.suite).jsonl")
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw EvalError.input("cannot write \(path)")
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let built = try streamedSuite(manifest, settings: settings, library: library) { try handle.write(contentsOf: $0) }
            entries.append(.init(report: built.report, sha256: built.sha256, bytes: built.bytes))
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
    /// `<directory>/build.json` as `cases build` wrote it.
    static func read(directory: String) throws -> BuildSummary {
        let path = (directory as NSString).appendingPathComponent("build.json")
        guard let data = FileManager.default.contents(atPath: path) else { throw EvalError.input("no such file: \(path)") }
        do { return try JSONDecoder().decode(BuildSummary.self, from: data) } catch {
            throw EvalError.input("\(path): \(error)")
        }
    }

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
