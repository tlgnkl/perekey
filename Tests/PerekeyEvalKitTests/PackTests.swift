// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyEvalKit
import Testing

/// `perekey-eval cases pack` (docs/eval.md, «Пакет случаев»): which suites go in, the bytes of the archive
/// and what lies in it.
@Suite struct PackTests {
    // MARK: - the archive

    @Test func tarBytesDoNotDependOnTheOrderOfTheEntries() throws {
        let entries = [TarArchive.Entry(path: "p/b.txt", data: Data("two".utf8)),
                       TarArchive.Entry(path: "p/a.txt", data: Data("one".utf8)),
                       TarArchive.Entry(path: "p/c/d.txt", data: Data())]
        let first = try TarArchive.bytes(entries)
        let second = try TarArchive.bytes(entries.reversed())
        #expect(first == second)
        #expect(first.count % 10240 == 0, "the archive is padded to a whole record, like tar does")
    }

    @Test func tarIsReadByTheSystemTarWithTheSameBytes() throws {
        let long = String(repeating: "d", count: 60)
        let entries = [TarArchive.Entry(path: "pack/\(long)/\(long).txt", data: Data((0..<1500).map { UInt8($0 % 251) })),
                       TarArchive.Entry(path: "pack/небо.txt", data: Data("текст".utf8)),
                       TarArchive.Entry(path: "pack/empty", data: Data())]
        let directory = try SuiteFixtures.directory()
        let file = directory + "/a.tar"
        try TarArchive.bytes(entries).write(to: URL(fileURLWithPath: file))
        let out = directory + "/out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try SuiteFixtures.run("/usr/bin/tar", ["-xf", file, "-C", out], in: directory)
        for entry in entries {
            #expect(try Data(contentsOf: URL(fileURLWithPath: out + "/" + entry.path)) == entry.data, "\(entry.path)")
        }
        // Nothing of the day or of the machine: owner 0, mode 0644, time 0.
        let header = try TarArchive.bytes(entries).prefix(512)
        let text = String(decoding: header, as: UTF8.self)
        #expect(text.contains("0000644"))
        #expect(text.contains("00000000000\0"), "mtime 0")
    }

    @Test func aPathTooLongForTheHeaderIsAnError() {
        let path = String(repeating: "x/", count: 300) + "f"
        #expect(throws: EvalError.self) { try TarArchive.bytes([.init(path: path, data: Data())]) }
    }

    // MARK: - what goes in

    @Test func everyManifestOfTheRepositoryIsEitherInTheStandardPackOrLeftOutWithAReason() throws {
        let manifests = try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
        let policy = PackPolicy.standard
        #expect(policy.problems(manifests: manifests) == [])
        let included = Set(policy.entries.map(\.suite))
        let excluded = Set(policy.excluded.keys)
        #expect(included.isDisjoint(with: excluded))
        #expect(included.union(excluded) == Set(manifests.map(\.suite)), "a new manifest needs a decision")
        for (suite, reason) in policy.excluded { #expect(reason.count > 10, "\(suite) has no reason") }
    }

    @Test func aSuiteWithoutAConfirmedLicenseIsNeverInThePack() throws {
        let policy = PackPolicy.standard
        // The sources whose licence is not confirmed (data/SOURCES.md) and the code, which is kept out of the public pack.
        for suite in ["class.code", "typos.real.ru", "social.ru"] {
            #expect(!policy.entries.contains { $0.suite == suite }, "\(suite) is in the pack")
        }
        #expect(policy.excluded["class.code"] != nil)
        #expect(!policy.entries.contains { $0.suite.hasPrefix("personal.") || $0.suite.hasPrefix("learning.") })
        var bad = PackPolicy.standard
        bad.entries.append(.init(suite: "personal.mine", sources: [.tatoeba]))
        #expect(bad.problems(manifests: []).contains { $0.contains("personal.mine") })
        var other = PackPolicy.standard
        other.entries.append(.init(suite: "social.ru", sources: []))
        #expect(!other.problems(manifests: []).isEmpty, "a suite with no source to attribute")
    }

    @Test func theStandardPackIsTheSuitesOfTheCiStepOfQualityShWithoutTheCode() throws {
        let script = try String(contentsOfFile: Repo.path("scripts/quality.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "CI_SUITES=("))
        let rest = script[start.upperBound...]
        let end = try #require(rest.firstIndex(of: ")"))
        let ci = rest[..<end].split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let packed = PackPolicy.standard.entries.map(\.suite)
        #expect(Set(packed) == Set(ci).subtracting(["class.code"]))
        #expect(PackPolicy.standard.excluded["class.code"]?.contains("SOURCES.md") == true)
    }

    @Test func theNameIsInOnePlace() {
        let policy = PackPolicy.standard
        #expect(policy.name == PackPolicy.packageName)
        #expect(policy.fileName == PackPolicy.packageName + ".tar.zst")
        #expect(policy.tier == .ci)
    }

    // MARK: - the pack

    /// A policy over the suite of the test cache.
    private func smallPolicy() -> PackPolicy {
        PackPolicy(name: "benchtest-v1", tier: .ci, entries: [.init(suite: "t.suite", sources: [.tatoeba])], excluded: [:])
    }

    private func environment() throws -> (suites: String, cache: String, work: String) {
        let suites = try SuiteFixtures.directory()
        let manifest = try SuiteFixtures.manifest("t.suite", source: SuiteFixtures.tatoeba)
        try CaseCodec.json(manifest).write(toFile: suites + "/t.suite.suite.json", atomically: true, encoding: .utf8)
        return (suites, try SuiteFixtures.tatoebaCache(), try SuiteFixtures.directory())
    }

    private func pack(_ env: (suites: String, cache: String, work: String), to name: String,
                      extra: [String] = []) throws -> (code: Int32, out: String, err: String) {
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "ci", "--suites", env.suites, "--cache", env.cache,
                              "--layouts", Repo.path("eval/layouts"), "--pack-dir", Repo.path("eval/pack"),
                              "--out", env.work + "/" + name] + extra,
                             policy: smallPolicy())
        }
        return (code, capture.stdout, capture.stderr)
    }

    @Test func thePackBuildsTwiceWithTheSameHash() throws {
        let env = try environment()
        let first = try pack(env, to: "one.tar.zst")
        #expect(first.code == 0, "\(first.err)")
        let second = try pack(env, to: "two.tar.zst")
        #expect(second.code == 0, "\(second.err)")
        let one = try Data(contentsOf: URL(fileURLWithPath: env.work + "/one.tar.zst"))
        let two = try Data(contentsOf: URL(fileURLWithPath: env.work + "/two.tar.zst"))
        #expect(!one.isEmpty)
        #expect(one == two)
        let sidecar = try String(contentsOfFile: env.work + "/one.tar.zst.sha256", encoding: .utf8)
        #expect(sidecar == "\(Runner.sha256(one))  one.tar.zst\n")
        #expect(first.out.contains(Runner.sha256(one)), "the command prints the hash")
        #expect(first.out.contains("tar sha256"), "and the hash of the tar, which does not depend on the zstd version")
    }

    @Test func thePackHoldsTheCasesTheDocumentsAndNothingElse() throws {
        let env = try environment()
        let result = try pack(env, to: "p.tar.zst")
        #expect(result.code == 0, "\(result.err)")
        let out = env.work + "/x"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try SuiteFixtures.run("/usr/bin/tar", ["-xf", env.work + "/p.tar.zst", "-C", out], in: env.work)
        let root = out + "/benchtest-v1"
        let listed = try FileManager.default.subpathsOfDirectory(atPath: root).sorted()
        #expect(listed == ["ATTRIBUTION.md", "LICENSE", "README.md", "cases", "cases/t.suite.jsonl", "pack.json"])
        let license = try String(contentsOfFile: root + "/LICENSE", encoding: .utf8)
        #expect(license.hasPrefix("Attribution-ShareAlike 4.0 International"))
        let readme = try String(contentsOfFile: root + "/README.md", encoding: .utf8)
        #expect(readme.contains("benchtest-v1"), "the template takes the name from the policy")
        #expect(!readme.contains("{{"))
        let attribution = try String(contentsOfFile: root + "/ATTRIBUTION.md", encoding: .utf8)
        #expect(attribution.contains("Tatoeba"))
        #expect(attribution.contains("tatoeba.org/sentences/show"))
        // The cases are the cases `cases build` writes, and they pass the check.
        let text = try String(contentsOfFile: root + "/cases/t.suite.jsonl", encoding: .utf8)
        let items = try CaseCodec.read(text, file: "t.suite.jsonl")
        #expect(!items.isEmpty)
        for item in items { #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty) }
        // pack.json: the hash of every file and of every source file.
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/pack.json"))) as? [String: Any])
        #expect(json["name"] as? String == "benchtest-v1")
        #expect(json["tier"] as? String == "ci")
        let sources = try #require(json["sources"] as? [String: String])
        #expect(sources["tatoeba/rus_sentences.tsv.bz2"] == (try Runner.sha256(file: env.cache + "/tatoeba/rus_sentences.tsv.bz2")))
        let build = try #require(json["build"] as? [String: Any])
        let suites = try #require(build["suites"] as? [[String: Any]])
        #expect(suites.first?["sha256"] as? String == Runner.sha256(Data(text.utf8)))
        let layouts = try #require(json["layouts"] as? [String: String])
        #expect(layouts["ABC"] == (try Runner.sha256(file: Repo.path("eval/layouts/ABC.json"))))
    }

    @Test func aPlayedPackNeedsNeitherTheSourcesNorTheirCache() throws {
        let env = try environment()
        #expect(try pack(env, to: "p.tar.zst").code == 0)
        // The sources are gone; the cases are all that is left, and they are played as they are.
        try FileManager.default.removeItem(atPath: env.cache)
        let out = env.work + "/x"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try SuiteFixtures.run("/usr/bin/tar", ["-xf", env.work + "/p.tar.zst", "-C", out], in: env.work)
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalContext.$environment.withValue(["PEREKEY_DATA_CACHE": env.cache + "/gone"]) {
                EvalCommands.run(["play", "--cases", out + "/benchtest-v1/cases", "--system", "null",
                                  "--layouts", Repo.path("eval/layouts"), "--out", env.work + "/run"])
            }
        }
        #expect(code == 0, "\(capture.stderr)")
        #expect(FileManager.default.fileExists(atPath: env.work + "/run/summary.json"))
    }

    @Test func aMissingSourceStopsThePackInsteadOfShrinkingIt() throws {
        let env = try environment()
        try FileManager.default.removeItem(atPath: env.cache + "/tatoeba/eng_sentences.tsv.bz2")
        let result = try pack(env, to: "p.tar.zst")
        #expect(result.code == 2)
        #expect(result.err.contains("t.suite") && result.err.contains("eng_sentences"))
        #expect(!FileManager.default.fileExists(atPath: env.work + "/p.tar.zst"))
    }

    @Test func onlyTheCiTierIsPacked() throws {
        let env = try environment()
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "full", "--suites", env.suites, "--cache", env.cache,
                              "--out", env.work + "/p.tar.zst"], policy: smallPolicy())
        }
        #expect(code == 2)
        #expect(capture.stderr.contains("ci"))
    }

    @Test func anOutputThatIsAFolderGetsTheNameOfThePolicy() throws {
        let env = try environment()
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "ci", "--suites", env.suites, "--cache", env.cache,
                              "--layouts", Repo.path("eval/layouts"), "--pack-dir", Repo.path("eval/pack"),
                              "--out", env.work], policy: smallPolicy())
        }
        #expect(code == 0, "\(capture.stderr)")
        #expect(FileManager.default.fileExists(atPath: env.work + "/benchtest-v1.tar.zst"))
        #expect(FileManager.default.fileExists(atPath: env.work + "/benchtest-v1.tar.zst.sha256"))
    }

    // MARK: - the texts

    @Test func everySourceOfThePolicyHasALicenseAndALink() {
        for source in PackSource.allCases {
            #expect(!source.title.isEmpty && !source.license.isEmpty && source.url.hasPrefix("https://"), "\(source)")
        }
        #expect(PackSource.tatoeba.license.contains("CC BY 2.0 FR"))
        #expect(PackSource.stackExchange.license.contains("CC BY-SA"))
    }

    @Test func theLicenseFileOfThePackIsTheCreativeCommonsText() throws {
        let text = try String(contentsOfFile: Repo.path("eval/pack/LICENSE"), encoding: .utf8)
        #expect(text.hasPrefix("Attribution-ShareAlike 4.0 International"))
        #expect(text.contains("Section 3 -- License Conditions."))
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Creative Commons may be contacted at creativecommons.org."))
    }

    @Test func theReadmeOfThePackDefinesTheOutcomes() throws {
        let text = try String(contentsOfFile: Repo.path("eval/pack/README.md"), encoding: .utf8)
        for word in ["harm", "fixed", "miss", "botched", "disputed", "spill", "{{name}}", "tokens", "play"] {
            #expect(text.contains(word), "\(word)")
        }
    }
}
