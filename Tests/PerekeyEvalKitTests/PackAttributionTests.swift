// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyEvalKit
import Testing

/// The authors and the licenses of the Stack Exchange posts a pack holds (`attribution-se.tsv`), and the check
/// that every source file of a set is one the license of the set covers.
@Suite struct PackAttributionTests {
    // MARK: - the license of a post

    @Test func theLicenseFollowsTheDateOfThePostBySiteRules() {
        // Stack Exchange: posts before 2011-04-08 are CC BY-SA 2.5, before 2018-05-02 CC BY-SA 3.0, later CC BY-SA 4.0.
        let cases = [("2008-09-15T10:00:00.000", "CC BY-SA 2.5"), ("2011-04-07T23:59:59.999", "CC BY-SA 2.5"),
                     ("2011-04-08T00:00:00.000", "CC BY-SA 3.0"), ("2018-05-01T23:59:59.999", "CC BY-SA 3.0"),
                     ("2018-05-02T00:00:00.000", "CC BY-SA 4.0"), ("2024-03-01T12:00:00.000", "CC BY-SA 4.0")]
        for (date, license) in cases { #expect(StackExchangeAttribution.licenseByDate(date) == license, "\(date)") }
        #expect(StackExchangeAttribution.licenseByDate("yesterday") == nil)
    }

    private func row(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func aRowGivesTheTypeTheUrlTheAuthorAndTheLicense() throws {
        let question = try StackExchangeAttribution.post(
            fromRow: row(#"  <row Id="7" PostTypeId="1" CreationDate="2012-01-02T03:04:05.000" OwnerUserId="42" ContentLicense="CC BY-SA 3.0" />"#),
            site: "rus.stackexchange.com")
        #expect(question == .init(id: "7", type: "question", site: "rus.stackexchange.com", url: "https://rus.stackexchange.com/q/7",
                                  author: "user:42", license: "CC BY-SA 3.0", licenseByDate: "CC BY-SA 3.0"))
        let answer = try StackExchangeAttribution.post(
            fromRow: row(#"  <row Id="8" PostTypeId="2" ParentId="7" CreationDate="2010-01-02T03:04:05.000" OwnerDisplayName="A &amp; B&#x9;C" />"#),
            site: "rus.stackexchange.com")
        #expect(answer.type == "answer" && answer.url == "https://rus.stackexchange.com/a/8")
        #expect(answer.author == "A & B C", "the name is unescaped and has no tab to break the table")
        #expect(answer.license == "CC BY-SA 2.5", "a dump with no license on the post: the date rule")
    }

    @Test func theLicenseOfTheDumpWinsOverTheDateRuleAndTheTwoAreKept() throws {
        let post = try StackExchangeAttribution.post(
            fromRow: row(#"<row Id="9" PostTypeId="2" CreationDate="2012-01-02T03:04:05.000" OwnerUserId="1" ContentLicense="CC BY-SA 4.0" />"#),
            site: "s")
        #expect(post.license == "CC BY-SA 4.0")
        #expect(post.licenseByDate == "CC BY-SA 3.0")
    }

    @Test func aPostWithoutAnAuthorStopsTheTable() {
        #expect(throws: EvalError.self) {
            try StackExchangeAttribution.post(
                fromRow: row(#"<row Id="9" PostTypeId="2" CreationDate="2012-01-02T03:04:05.000" />"#), site: "s.stackexchange.com")
        }
        do {
            _ = try StackExchangeAttribution.post(
                fromRow: row(#"<row Id="9" PostTypeId="2" CreationDate="2012-01-02T03:04:05.000" />"#), site: "s.stackexchange.com")
        } catch {
            #expect("\(error)".contains("9") && "\(error)".contains("s.stackexchange.com"), "the error names the post")
        }
    }

    @Test func aPostWithoutADateOrALicenseIsAnErrorToo() {
        #expect(throws: EvalError.self) {
            try StackExchangeAttribution.post(fromRow: row(#"<row Id="9" PostTypeId="2" OwnerUserId="1" />"#), site: "s")
        }
    }

    // MARK: - the pack with Stack Exchange

    /// A dump of 120 posts in the shape of `Posts.xml`, in a `.7z` the system `tar` reads.
    private func dump(authors: Bool = true) throws -> (cache: String, work: String) {
        let cache = try SuiteFixtures.directory()
        let work = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: cache + "/stackexchange", withIntermediateDirectories: true)
        var xml = "\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<posts>\n"
        for index in 1...120 {
            let words = (0..<9).map { SuiteFixtures.russianWords[(index * 5 + $0 * 3) % SuiteFixtures.russianWords.count] }
            let body = "&lt;p&gt;" + words.joined(separator: " ").capitalized + ".&lt;/p&gt;"
            let date = index <= 40 ? "2010-05-01T10:00:00.000" : index <= 80 ? "2014-05-01T10:00:00.000" : "2020-05-01T10:00:00.000"
            let license = index <= 40 ? "" : index <= 80 ? #" ContentLicense="CC BY-SA 3.0""# : #" ContentLicense="CC BY-SA 4.0""#
            let owner = !authors ? "" : index % 7 == 0 ? #" OwnerDisplayName="Иван &amp; Ко""# : #" OwnerUserId="\#(100 + index)""#
            xml += #"  <row Id="\#(index)" PostTypeId="\#(index % 2 == 0 ? 2 : 1)" CreationDate="\#(date)" Body="\#(body)"\#(owner)\#(license) />"# + "\n"
        }
        xml += "</posts>\n"
        try xml.write(toFile: cache + "/Posts.xml", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/tar", ["--format", "7zip", "-cf", cache + "/stackexchange/t.stackexchange.com.7z", "Posts.xml"], in: cache)
        return (cache, work)
    }

    private func seSuites() throws -> String {
        let suites = try SuiteFixtures.directory()
        let manifest = try SuiteFixtures.manifest("t.se", reader: "stackexchange", source: "stackexchange/t.stackexchange.com.7z",
                                                  scenarios: ["clean.cold", "slip.cold"], tier: 300,
                                                  extra: ",\"filter\":{\"minTokens\":8}")
        try CaseCodec.json(manifest).write(toFile: suites + "/t.se.suite.json", atomically: true, encoding: .utf8)
        return suites
    }

    private func pack(cache: String, work: String, suites: String, name: String = "se.tar.zst") -> (code: Int32, out: String, err: String) {
        let policy = PackPolicy(name: "benchtest-v1", tier: .ci, entries: [.init(suite: "t.se", sources: [.stackExchange])], excluded: [:])
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "ci", "--suites", suites, "--cache", cache,
                              "--layouts", Repo.path("eval/layouts"), "--pack-dir", Repo.path("eval/pack"),
                              "--out", work + "/" + name], policy: policy)
        }
        return (code, capture.stdout, capture.stderr)
    }

    private func unpack(_ work: String, _ name: String = "se.tar.zst") throws -> String {
        let out = work + "/x-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try SuiteFixtures.run("/usr/bin/tar", ["-xf", work + "/" + name, "-C", out], in: work)
        return out + "/benchtest-v1"
    }

    @Test func thePackHoldsOneRowForEveryPostItsCasesName() throws {
        let (cache, work) = try dump()
        let result = pack(cache: cache, work: work, suites: try seSuites())
        #expect(result.code == 0, "\(result.err)")
        let root = try unpack(work)
        let table = try String(contentsOfFile: root + "/attribution-se.tsv", encoding: .utf8)
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "post_id\ttype\tsite\turl\tauthor\tlicense")
        #expect(lines.last == "")
        let rows = lines.dropFirst().dropLast().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows.allSatisfy { $0.count == 6 })
        // Every post the cases name is in the table, once, and no other post.
        let cases = try String(contentsOfFile: root + "/cases/t.se.jsonl", encoding: .utf8)
        var named = Set<String>()
        for line in cases.split(separator: "\n") {
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let ref = try #require((object["meta"] as? [String: Any])?["ref"] as? String)
            named.insert(String(ref.dropFirst("post:".count).prefix { $0 != "#" }))
        }
        #expect(Set(rows.map { $0[0] }) == named)
        #expect(rows.count == named.count)
        #expect(rows.map { Int($0[0])! } == rows.map { Int($0[0])! }.sorted(), "sorted by the number of the post")
        let first = try #require(rows.first)
        let id = Int(first[0])!
        #expect(first[1] == (id % 2 == 0 ? "answer" : "question"))
        #expect(first[2] == "t.stackexchange.com")
        #expect(first[3] == "https://t.stackexchange.com/\(id % 2 == 0 ? "a" : "q")/\(id)")
        #expect(first[4] == (id % 7 == 0 ? "Иван & Ко" : "user:\(100 + id)"))
        #expect(first[5] == (id <= 40 ? "CC BY-SA 2.5" : id <= 80 ? "CC BY-SA 3.0" : "CC BY-SA 4.0"))
    }

    @Test func theCasesAreCountedByTheLicenseOfTheirPost() throws {
        let (cache, work) = try dump()
        let result = pack(cache: cache, work: work, suites: try seSuites())
        #expect(result.code == 0, "\(result.err)")
        let root = try unpack(work)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: root + "/pack.json"))) as? [String: Any])
        let counts = try #require(json["stackExchangeCases"] as? [String: Int])
        let cases = try String(contentsOfFile: root + "/cases/t.se.jsonl", encoding: .utf8)
        #expect(counts.values.reduce(0, +) == cases.split(separator: "\n").count)
        #expect(Set(counts.keys).isSubset(of: ["CC BY-SA 2.5", "CC BY-SA 3.0", "CC BY-SA 4.0"]))
        #expect(counts.count == 3, "the fixture has posts of all three")
        for license in ["2.5", "3.0", "4.0"] { #expect(result.out.contains("CC BY-SA \(license)"), "the command prints the count of \(license)") }
    }

    @Test func theTextsDoNotCallTheWholePackFourPointZero() throws {
        let (cache, work) = try dump()
        #expect(pack(cache: cache, work: work, suites: try seSuites()).code == 0)
        let root = try unpack(work)
        let attribution = try String(contentsOfFile: root + "/ATTRIBUTION.md", encoding: .utf8)
        let readme = try String(contentsOfFile: root + "/README.md", encoding: .utf8)
        for (name, text) in [("ATTRIBUTION.md", attribution), ("README.md", readme)] {
            #expect(!text.contains("as a whole is offered under CC BY-SA 4.0"), name)
            #expect(text.contains("attribution-se.tsv"), name)
            #expect(text.contains("license of its source"), "\(name): the text of a case keeps the license of its source")
        }
        #expect(attribution.contains("2011-04-08") && attribution.contains("2018-05-02"), "the rule of the dates")
        #expect(readme.contains("our annotation") || readme.contains("our markup"), "LICENSE is for what we made")
    }

    @Test func aPostWithoutAnAuthorStopsThePack() throws {
        let (cache, work) = try dump(authors: false)
        let result = pack(cache: cache, work: work, suites: try seSuites())
        #expect(result.code == 2)
        #expect(result.err.contains("t.stackexchange.com") && result.err.contains("author"))
        #expect(!FileManager.default.fileExists(atPath: work + "/se.tar.zst"))
    }

    @Test func theTableAndThePackAreTheSameTwice() throws {
        let (cache, work) = try dump()
        let suites = try seSuites()
        #expect(pack(cache: cache, work: work, suites: suites, name: "a.tar.zst").code == 0)
        #expect(pack(cache: cache, work: work, suites: suites, name: "b.tar.zst").code == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: work + "/a.tar.zst")) == Data(contentsOf: URL(fileURLWithPath: work + "/b.tar.zst")))
    }

    @Test func aPackWithNoStackExchangeHasNoTable() throws {
        let suites = try SuiteFixtures.directory()
        try CaseCodec.json(SuiteFixtures.manifest("t.suite", source: SuiteFixtures.tatoeba))
            .write(toFile: suites + "/t.suite.suite.json", atomically: true, encoding: .utf8)
        let cache = try SuiteFixtures.tatoebaCache(), work = try SuiteFixtures.directory()
        let policy = PackPolicy(name: "benchtest-v1", tier: .ci, entries: [.init(suite: "t.suite", sources: [.tatoeba])], excluded: [:])
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "ci", "--suites", suites, "--cache", cache,
                              "--layouts", Repo.path("eval/layouts"), "--pack-dir", Repo.path("eval/pack"),
                              "--out", work + "/p.tar.zst"], policy: policy)
        }
        #expect(code == 0, "\(capture.stderr)")
        let root = try unpack(work, "p.tar.zst")
        #expect(!FileManager.default.fileExists(atPath: root + "/attribution-se.tsv"))
    }

    // MARK: - the source of a set against its license

    @Test func aSourceFileOutsideTheSourcesOfTheSetRefusesThePack() throws {
        let manifest = try SuiteFixtures.manifest("prose.tatoeba", source: "tatoeba/rus_sentences.tsv.bz2,social.ru/x")
        let problems = PackPolicy.standard.problems(manifests: [manifest])
        let found = try #require(problems.first { $0.contains("social.ru/x") })
        #expect(found.contains("prose.tatoeba"))
    }

    @Test func theCarrierAndTheCorpusAreChecked() throws {
        let carrier = try SuiteFixtures.manifest(
            "typos.real.en", reader: "misspellings", source: "wikipedia-misspellings/for-machines.txt", scenarios: ["fix"],
            extra: ",\"correction\":{\"kind\":\"typo.real\"},\"carrier\":\"social.ru/carrier.bz2\"")
        #expect(PackPolicy.standard.problems(manifests: [carrier]).contains { $0.contains("social.ru/carrier.bz2") })
        // class.names: GeoNames and the Tatoeba of its warm-up are the entry's; social.ru is not.
        #expect(PackPolicy.standard.unlicensed(files: ["geonames/cities15000.zip", "social.ru/y", "tatoeba/rus_sentences.tsv.bz2"],
                                               suite: "class.names") == ["social.ru/y"])
    }

    @Test func aFileOfAnotherSourceThanTheEntryNamesIsRefused() {
        let policy = PackPolicy.standard
        // class.names: GeoNames, Wikidata, word lists, Tatoeba; not Stack Exchange.
        #expect(policy.unlicensed(files: ["stackexchange/rus.stackexchange.com.7z"], suite: "class.names") == ["stackexchange/rus.stackexchange.com.7z"])
        #expect(policy.unlicensed(files: ["geonames/cities15000.zip", "tatoeba/eng_sentences.tsv.bz2"], suite: "class.names") == [])
        // A suite that is not in the pack has no allowed file.
        #expect(policy.unlicensed(files: ["tatoeba/eng_sentences.tsv.bz2"], suite: "social.ru") == ["tatoeba/eng_sentences.tsv.bz2"])
        // A prefix is a folder: a name that only starts with the same letters is another source.
        #expect(policy.unlicensed(files: ["tatoebaX/rus.bz2", "tatoeba"], suite: "prose.tatoeba") == ["tatoebaX/rus.bz2", "tatoeba"])
    }

    @Test func thePackCommandRefusesBeforeItBuildsAnything() throws {
        let suites = try SuiteFixtures.directory()
        let manifest = try SuiteFixtures.manifest("t.suite", source: SuiteFixtures.tatoeba + ",social.ru/x")
        try CaseCodec.json(manifest).write(toFile: suites + "/t.suite.suite.json", atomically: true, encoding: .utf8)
        let cache = try SuiteFixtures.tatoebaCache(), work = try SuiteFixtures.directory()
        let policy = PackPolicy(name: "benchtest-v1", tier: .ci, entries: [.init(suite: "t.suite", sources: [.tatoeba])], excluded: [:])
        let capture = EvalContext.Capture()
        let code = EvalContext.$capture.withValue(capture) {
            EvalCommands.run(["cases", "pack", "--tier", "ci", "--suites", suites, "--cache", cache,
                              "--layouts", Repo.path("eval/layouts"), "--pack-dir", Repo.path("eval/pack"),
                              "--out", work + "/p.tar.zst"], policy: policy)
        }
        #expect(code == 2)
        #expect(capture.stderr.contains("social.ru/x") && capture.stderr.contains("t.suite"))
        #expect(!FileManager.default.fileExists(atPath: work + "/p.tar.zst"))
    }

    // MARK: - the version of zstd

    @Test func theVersionOfZstdIsReadFromTheTool() throws {
        let version = try Zstd.version()
        #expect(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil, "\(version)")
    }

    @Test func theReadmeNamesTheVersionAndTheTarHashSitsBesideTheArchive() throws {
        let (cache, work) = try dump()
        let result = pack(cache: cache, work: work, suites: try seSuites())
        #expect(result.code == 0, "\(result.err)")
        let version = try Zstd.version()
        let readme = try String(contentsOfFile: try unpack(work) + "/README.md", encoding: .utf8)
        #expect(readme.contains("zstd \(version)"), "the README names the zstd the hash was made with")
        #expect(!readme.contains("{{"))
        // The hash of the uncompressed tar is beside the archive (it cannot be inside the tar) and is the one of `zstd -d`.
        let sidecar = try String(contentsOfFile: work + "/se.tar.zst.tar.sha256", encoding: .utf8)
        let tar = try SuiteFixtures.capture(try Zstd.executable(), ["-dc", work + "/se.tar.zst"])
        #expect(sidecar == "\(Runner.sha256(tar))  se.tar\n")
        #expect(result.out.contains("zstd \(version)"))
    }
}

extension SuiteFixtures {
    /// The standard output of a tool.
    static func capture(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
