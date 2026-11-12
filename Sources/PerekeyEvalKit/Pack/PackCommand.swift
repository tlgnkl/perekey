// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `perekey-eval cases pack` (docs/eval.md, «Пакет случаев»):
///
///     perekey-eval cases pack --tier ci --out <file.tar.zst or folder> [--suites <dir>] [--cache <dir>]
///                             [--layouts <dir>] [--lexicon <dir>] [--classes <dir>] [--pack-dir <dir>]
///
/// Builds the cases of every suite the policy puts in the pack, writes them with the license, the attribution, the
/// README and `pack.json` into one deterministic tar, and compresses it with zstd. A source missing from the cache
/// is an error: a pack that quietly lost a suite would be a different pack under the same name. Writes
/// `<file>.sha256` beside the file and prints both hashes; the hash of the tar does not depend on the version of zstd.
extension EvalCommands {
    static func pack(_ parsed: Arguments, policy: PackPolicy) throws -> Int32 {
        guard let out = parsed.value("--out") else { throw EvalError.input("pack: --out <file.tar.zst or folder> is required") }
        guard (parsed.value("--tier") ?? policy.tier.rawValue) == policy.tier.rawValue else {
            throw EvalError.input("pack: the pack has one tier, \(policy.tier.rawValue)")
        }
        for flag in ["--only", "--epoch"] where parsed.value(flag) != nil {
            throw EvalError.input("pack: \(flag) does not apply: the pack is the whole of epoch \(policy.epoch) of its suites")
        }
        let settings = try BuildSettings(parsed)
        let library = try parsed.library()
        let manifests = try SuiteManifestFiles.read(directory: settings.suites)
        let problems = policy.problems(manifests: manifests)
        guard problems.isEmpty else { throw EvalError.input("pack: " + problems.joined(separator: "\npack: ")) }
        let chosen = manifests.filter { manifest in policy.entries.contains { $0.suite == manifest.suite } }
            .sorted { $0.suite < $1.suite }
        for manifest in chosen {
            if let missing = settings.missingSource(of: manifest) {
                throw EvalError.input("pack: suite \(manifest.suite): no source \(missing) in \(settings.cache)")
            }
        }
        let layoutsDirectory = parsed.value("--layouts") ?? "eval/layouts"
        let packDirectory = parsed.value("--pack-dir") ?? "eval/pack"

        var files: [TarArchive.Entry] = []
        var entries: [BuildSummary.Entry] = []
        var sources: [String: String] = [:]
        var licenses: [String: String] = [:]
        var layouts: Set<String> = []
        for manifest in chosen {
            let built = try builtSuite(manifest, settings: settings, library: library)
            files.append(.init(path: "\(policy.name)/cases/\(manifest.suite).jsonl", data: built.bytes))
            entries.append(.init(report: built.report, sha256: built.sha256, bytes: built.bytes.count))
            licenses[manifest.suite] = manifest.license
            layouts.formUnion(manifest.layoutSets.flatMap { $0 })
            for name in manifest.sources { sources[name] = try PackSourceHashes.hash(name, cache: settings.cache) }
            for (name, hash) in built.report.classes?.files ?? [:] { sources[name] = hash }
            EvalContext.out(Console.buildLine(built.report, sha256: built.sha256))
        }
        let summary = BuildSummary(tier: policy.tier.rawValue, suites: entries)
        let info = PackInfo(name: policy.name, tier: policy.tier.rawValue, epoch: policy.epoch, build: summary, licenses: licenses,
                            sources: sources, layouts: try layouts.sorted().reduce(into: [:]) {
                                $0[$1] = try Runner.sha256(file: (layoutsDirectory as NSString).appendingPathComponent($1 + ".json"))
                            })
        let texts = try PackTexts(directory: packDirectory)
        files.append(.init(path: "\(policy.name)/pack.json", data: Data((try CaseCodec.json(info) + "\n").utf8)))
        files.append(.init(path: "\(policy.name)/LICENSE", data: Data(texts.license.utf8)))
        files.append(.init(path: "\(policy.name)/README.md", data: Data(texts.readme(policy: policy, summary: summary).utf8)))
        files.append(.init(path: "\(policy.name)/ATTRIBUTION.md", data: Data(texts.attribution(policy: policy, summary: summary).utf8)))

        let tar = try TarArchive.bytes(files)
        var isDirectory: ObjCBool = false
        let target = FileManager.default.fileExists(atPath: out, isDirectory: &isDirectory) && isDirectory.boolValue
            ? (out as NSString).appendingPathComponent(policy.fileName) : out
        let temporary = target + ".part"
        defer {
            try? FileManager.default.removeItem(atPath: temporary + ".tar")
            try? FileManager.default.removeItem(atPath: temporary)
        }
        try tar.write(to: URL(fileURLWithPath: temporary + ".tar"))
        try Zstd.compress(temporary + ".tar", to: temporary)
        if FileManager.default.fileExists(atPath: target) { try FileManager.default.removeItem(atPath: target) }
        try FileManager.default.moveItem(atPath: temporary, toPath: target)
        let hash = try Runner.sha256(file: target)
        try "\(hash)  \((target as NSString).lastPathComponent)\n".write(toFile: target + ".sha256", atomically: true, encoding: .utf8)
        let cases = entries.reduce(0) { $0 + $1.report.scenarios.values.reduce(0) { $0 + $1.cases } }
        EvalContext.out("pack \(policy.name)  tier \(policy.tier.rawValue)  suites \(entries.count)  cases \(cases)  files \(files.count)")
        EvalContext.out("tar sha256  \(Runner.sha256(tar))  (\(tar.count) bytes)")
        EvalContext.out("sha256  \(hash)  \(target)")
        return 0
    }
}

/// `pack.json`: what the pack was made of, so that a second pack can be compared with it.
struct PackInfo: Codable {
    var format = 1
    var name: String
    var tier: String
    var epoch: Int
    var caseFormat = 1
    var license = "CC BY-SA 4.0"
    /// The counts and the SHA-256 of each suite file, as `cases build` writes them to `build.json`.
    var build: BuildSummary
    /// The license line of each manifest.
    var licenses: [String: String]
    /// The SHA-256 of every source file the cases were made from, by the name in the data cache.
    var sources: [String: String]
    /// The SHA-256 of the layout snapshots the cases are typed on; `play` needs the same files.
    var layouts: [String: String]
}

/// The hash of a source file once per build.
enum PackSourceHashes {
    static func hash(_ name: String, cache: String) throws -> String {
        try Runner.sha256(file: (cache as NSString).appendingPathComponent(name))
    }
}

/// The texts of the pack: the license and the README are files of `eval/pack`, the attribution is written from the policy.
struct PackTexts {
    let license: String
    private let readmeTemplate: String

    init(directory: String) throws {
        func read(_ name: String) throws -> String {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { throw EvalError.input("pack: no file \(path)") }
            return text
        }
        license = try read("LICENSE")
        readmeTemplate = try read("README.md")
    }

    func readme(policy: PackPolicy, summary: BuildSummary) -> String {
        var table = "| Set | Cases | Tokens | dev | test |\n|---|---:|---:|---:|---:|\n"
        for entry in summary.suites.sorted(by: { $0.report.suite < $1.report.suite }) {
            let stats = entry.report.scenarios.values
            table += "| `\(entry.report.suite)` | \(stats.reduce(0) { $0 + $1.cases }) | \(stats.reduce(0) { $0 + $1.tokens }) "
                + "| \(stats.reduce(0) { $0 + $1.dev }) | \(stats.reduce(0) { $0 + $1.test }) |\n"
        }
        return readmeTemplate
            .replacingOccurrences(of: "{{contents}}", with: table)
            .replacingOccurrences(of: "{{file}}", with: policy.fileName)
            .replacingOccurrences(of: "{{name}}", with: policy.name)
            .replacingOccurrences(of: "{{tier}}", with: policy.tier.rawValue)
    }

    func attribution(policy: PackPolicy, summary: BuildSummary) -> String {
        let used = Set(policy.entries.flatMap(\.sources))
        var text = "# Attribution\n\n`\(policy.name)` is made of text and word lists that other people wrote. "
            + "Each source, its license and the way to find the authors are below. "
            + "The pack as a whole is offered under CC BY-SA 4.0 (`LICENSE`); the license of a source stays with its text.\n\n"
        for source in PackSource.allCases where used.contains(source) {
            text += "## \(source.title)\n\n- License: \(source.license)\n- Source: <\(source.url)>\n- \(source.attribution)\n\n"
        }
        text += "## Which set holds which source\n\n| Set | Sources |\n|---|---|\n"
        for entry in policy.entries.sorted(by: { $0.suite < $1.suite }) {
            text += "| `\(entry.suite)` | \(entry.sources.map(\.title).joined(separator: "; ")) |\n"
        }
        text += "\nThe files of the sources, with their SHA-256, are in `pack.json` (`sources`).\n"
        return text
    }
}
