// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// Manifests and the helpers that make test sources.
enum SuiteFixtures {
    static func manifest(_ name: String = "t.suite", reader: String = "tatoeba", source: String = "src",
                         scenarios: [String] = ["clean.cold", "clean.warm", "slip.cold", "slip.warm"],
                         tier: Int = 400, dev: Int = 20, extra: String = "") throws -> SuiteManifest
    {
        let list = scenarios.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"suite":"\(name)","version":1,"epoch":1,"seed":7,"about":"test","reader":"\(reader)","source":"\(source)",
         "license":"test","sampling":"token","layoutSets":[["ABC","Russian"]],"scenarios":[\(list)],
         "tiers":{"ci":\(tier),"full":\(tier * 2)},"split":{"dev":\(dev),"by":"unit"}\(extra)}
        """
        return try JSONDecoder().decode(SuiteManifest.self, from: Data(json.utf8))
    }

    /// A fresh directory for one test.
    static func directory() throws -> String {
        let path = NSTemporaryDirectory() + "perekey-suite-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func run(_ tool: String, _ arguments: [String], in directory: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static let russianWords = ["давай", "мы", "завтра", "обсудим", "новый", "проект", "потом", "вечером", "погуляем",
                               "в", "парке", "если", "будет", "хорошая", "погода", "и", "сделаем", "всё", "быстро"]
    static let englishWords = ["we", "will", "talk", "about", "the", "project", "tomorrow", "and", "then", "walk",
                               "in", "the", "park", "if", "weather", "is", "nice", "enough", "today"]

    /// A Tatoeba cache with `count` sentences of each language: `id\tlang\ttext`, bzip2.
    static func tatoebaCache(count: Int = 300, englishCount: Int? = nil) throws -> String {
        let cache = try directory()
        try FileManager.default.createDirectory(atPath: cache + "/tatoeba", withIntermediateDirectories: true)
        for (code, words) in [("rus", russianWords), ("eng", englishWords)] {
            var text = ""
            for index in 0..<(code == "eng" ? englishCount ?? count : count) {
                let length = 8 + index % 4
                let sentence = (0..<length).map { words[(index * 7 + $0 * 3) % words.count] }.joined(separator: " ")
                text += "\(index + 1)\t\(code)\t\(sentence.prefix(1).uppercased() + sentence.dropFirst()).\n"
            }
            let file = "\(cache)/tatoeba/\(code)_sentences.tsv"
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            try run("/usr/bin/bzip2", ["-f", file], in: cache)
        }
        return cache
    }

    static let tatoeba = "tatoeba/rus_sentences.tsv.bz2,tatoeba/eng_sentences.tsv.bz2"
}

@Suite struct SuiteManifestTests {
    @Test func theManifestsOfTheRepositoryRead() throws {
        let manifests = try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
        // The corpus suites are there; the suites of other lanes (corrections, classes) come beside them.
        let names = Set(manifests.map(\.suite))
        for name in ["chat.tatoeba", "lang.rus-se", "lang.russian-se", "mixed.uk-se", "prose.be", "prose.kk",
                     "prose.tatoeba", "prose.uk", "tech.ruso"]
        {
            #expect(names.contains(name), "no manifest \(name)")
        }
        #expect(names.count == manifests.count)
        for manifest in manifests {
            #expect(manifest.problems().isEmpty)
            for set in manifest.layoutSets { _ = try LayoutSet(names: set, library: Repo.library) }
        }
    }

    @Test func anUnknownFieldIsAnError() throws {
        let json = try CaseCodec.json(SuiteFixtures.manifest()).replacingOccurrences(of: "\"suite\"", with: "\"extra\":1,\"suite\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SuiteManifest.self, from: Data(json.utf8)) }
    }

    @Test func anUnknownScenarioOrTwoSetsOfOneLayoutAreProblems() throws {
        var manifest = try SuiteFixtures.manifest(scenarios: ["clean.cold", "slip.never"])
        #expect(manifest.problems().contains("unknown scenario slip.never"))
        manifest = try SuiteFixtures.manifest()
        manifest.layoutSets = [["ABC", "ABC"]]
        #expect(!manifest.problems().isEmpty)
        manifest.layoutSets = [["ABC", "Russian"]]
        manifest.sampling = .type
        #expect(!manifest.problems().isEmpty)
    }

    @Test func theFileNameMustBeTheSuiteName() throws {
        let directory = try SuiteFixtures.directory()
        let json = try CaseCodec.json(SuiteFixtures.manifest("a.b"))
        try json.write(toFile: directory + "/other.suite.json", atomically: true, encoding: .utf8)
        #expect(throws: EvalError.self) { try SuiteManifestFiles.read(file: directory + "/other.suite.json") }
    }

    @Test func aManifestWritesAndReadsBack() throws {
        let manifest = try SuiteFixtures.manifest(extra: ",\"filter\":{\"minTokens\":2,\"requireScripts\":[\"cyrillic\"]},\"tags\":[\"x\"]")
        let back = try JSONDecoder().decode(SuiteManifest.self, from: Data(CaseCodec.json(manifest).utf8))
        #expect(back == manifest)
    }
}

@Suite struct SourceTextTests {
    @Test func sentencesBreakAtAStopAndACapital() {
        #expect(SourceText.sentences(of: "Привет, мир. Как дела? Хорошо! да, нет.") == ["Привет, мир.", "Как дела?", "Хорошо! да, нет."])
        #expect(SourceText.sentences(of: "Он сказал: «Иду.» Потом ушёл.") == ["Он сказал: «Иду.»", "Потом ушёл."])
    }

    @Test func aSingleLetterBeforeTheDotIsAnAbbreviation() {
        #expect(SourceText.sentences(of: "Это А. С. Пушкин, т. е. поэт.") == ["Это А. С. Пушкин, т. е. поэт."])
        #expect(SourceText.sentences(of: "Версия 1.2 готова. 3 пункта") == ["Версия 1.2 готова.", "3 пункта"])
    }

    @Test func aBodyLosesBlocksOfCodeAndKeepsCodeInTheLine() {
        let body = "&lt;p&gt;Вызовите &lt;code&gt;foo()&lt;/code&gt; сначала.&lt;/p&gt;&lt;pre&gt;&lt;code&gt;x = 1\ny = 2&lt;/code&gt;&lt;/pre&gt;&lt;p&gt;Потом &lt;a href=\"u\"&gt;ссылка&lt;/a&gt;, всё.&lt;/p&gt;"
        let paragraphs = SourceText.paragraphs(fromBody: body)
        #expect(paragraphs == ["Вызовите \u{E000}foo()\u{E001} сначала.", "Потом ссылка, всё."])
    }

    @Test func entitiesAreReadOnceForTheMarkupAndOnceForTheText() {
        #expect(SourceText.paragraphs(fromBody: "&lt;p&gt;a &amp;lt; b &amp;amp; c&lt;/p&gt;") == ["a < b & c"])
        #expect(SourceText.unescapeXML("&#1087;&#x440;&quot;&nbsp;&unknown;") == "пр\" &unknown;")
    }
}

@Suite struct ReaderTests {
    @Test func aTatoebaLineIsAUnit() {
        let unit = TatoebaReader.unit(fromLine: "12\trus\tПривет, мир.")
        #expect(unit == SourceUnit(ref: "tatoeba:rus#12", text: "Привет, мир."))
        #expect(TatoebaReader.unit(fromLine: "broken line") == nil)
    }

    @Test func aRowGivesSentencesWithTheirNumberInThePost() {
        let row: Substring = " <row Id=\"77\" ParentId=\"5\" Body=\"&lt;p&gt;Раз два. Три четыре.&lt;/p&gt;&lt;p&gt;Пять.&lt;/p&gt;\" />"
        #expect(StackExchangeReader.units(fromRow: row).map(\.ref) == ["post:77#0", "post:77#1", "post:77#2"])
        #expect(StackExchangeReader.units(fromRow: " <row ParentId=\"5\" Body=\"x\" />").isEmpty)
    }

    @Test func linesComeAcrossChunksAndEndWithoutANewline() throws {
        let directory = try SuiteFixtures.directory()
        // More than one 1 MiB chunk; the last line has no line end.
        var text = ""
        for index in 0..<60000 { text += "\(index)\trus\tстрока номер \(index) с текстом\r\n" }
        text += "last\trus\tконец"
        try text.write(toFile: directory + "/s.tsv", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/bzip2", ["s.tsv"], in: directory)
        var refs: [String] = []
        try TatoebaReader.forEachUnit(path: directory + "/s.tsv.bz2") { refs.append($0.ref) }
        #expect(refs.count == 60001)
        #expect(refs.first == "tatoeba:rus#0" && refs.last == "tatoeba:rus#last")
    }

    @Test func aStackExchangeArchiveIsReadAsAStream() throws {
        let directory = try SuiteFixtures.directory()
        let rows = """
        <?xml version="1.0" encoding="utf-8"?>
        <posts>
          <row Id="1" PostTypeId="1" Body="&lt;p&gt;Первый пост. Второе предложение.&lt;/p&gt;" />
          <row Id="2" PostTypeId="2" ParentId="1" Body="&lt;p&gt;Ответ здесь.&lt;/p&gt;" />
        </posts>
        """
        try rows.replacingOccurrences(of: "\n", with: "\r\n").write(toFile: directory + "/Posts.xml", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/tar", ["--format", "7zip", "-cf", "x.7z", "Posts.xml"], in: directory)
        var refs: [String] = []
        try StackExchangeReader.forEachUnit(path: directory + "/x.7z") { refs.append($0.ref) }
        #expect(refs == ["post:1#0", "post:1#1", "post:2#0"])
    }

    @Test func aMissingSourceNamesTheFile() throws {
        let manifest = try SuiteFixtures.manifest(source: "tatoeba/none.bz2")
        #expect(throws: EvalError.self) { try SourceReader.forEachUnit(manifest, cache: "/nonexistent") { _, _, _ in } }
    }
}

@Suite struct UnitParserTests {
    let set = try! LayoutSet(names: ["ABC", "Russian"], library: Repo.library)

    func parse(_ text: String, filter: SuiteManifest.Filter? = nil, extra: String = "") throws -> Result<ParsedUnit, Drop> {
        UnitParser.parse(text, manifest: try SuiteFixtures.manifest(extra: extra), set: set, library: Repo.library, filter: filter)
    }

    @Test func aMixedTokenIsCutByScriptAndMarksJoinTheRunBeforeThem() {
        #expect(UnitParser.segments(of: "USB-порт").map(\.text) == ["USB-", "порт"])
        #expect(UnitParser.segments(of: "(привет),").map(\.text) == ["(привет),"])
        #expect(UnitParser.segments(of: "15:30").map(\.script) == [nil])
        #expect(UnitParser.segments(of: "«a»б").map(\.text) == ["«a»", "б"])
    }

    @Test func aTokenWithNoLetterAimsWhereTheTokenBeforeIt() throws {
        let unit = try parse("zoom - привет 15:30").get()
        #expect(unit.aims == [["ABC"], ["ABC"], ["Russian"], ["Russian"]])
        let leading = try parse("123 привет").get()
        #expect(leading.aims.map { $0[0] } == ["Russian", "Russian"])
    }

    @Test func theKeyboardTypesTheMarksOfPrint() throws {
        let unit = try parse("«Привет» — сказал он…").get()
        #expect(unit.tokens.map(\.text) == ["\"Привет\"", "-", "сказал", "он..."])
        #expect(try parse("«Привет»", extra: ",\"normalize\":\"none\"") .isFailure(.unprintable))
    }

    @Test func lengthScriptAndUnprintableDropTheUnit() throws {
        #expect(try parse("раз два", filter: .init(minTokens: 3)).isFailure(.tooShort))
        #expect(try parse("раз два три", filter: .init(maxTokens: 2)).isFailure(.tooLong))
        #expect(try parse("12 34").isFailure(.noLetters))
        #expect(try parse("one two", filter: .init(requireScripts: [.cyrillic])).isFailure(.missingScript))
        #expect(try parse("日本語 text").isFailure(.otherScript))
        #expect(try parse("café au lait").isFailure(.unprintable))
        #expect(try parse("tab\u{7F}x").isFailure(.unprintable))
    }

    @Test func aNamedEntityTheReaderDoesNotKnowDropsTheUnit() throws {
        #expect(try parse("цена 5 &euro; за штуку").isFailure(.entity))
        #expect(try parse("текст &#xZZ; и ещё слова").isFailure(.entity))
        // Not entities: a bare ampersand, a pair of words, a read entity.
        #expect(try parse("Том & Джерри; снова вместе").isFailure(.entity) == false)
        let read = SourceText.paragraphs(fromBody: "&lt;p&gt;a &amp;amp; b &amp;laquo;x&amp;raquo;&lt;/p&gt;")
        #expect(read == ["a & b «x»"])
    }

    @Test func theReportNamesTheCharactersTheSetCannotType() throws {
        let manifest = try SuiteFixtures.manifest(extra: ",\"normalize\":\"none\"")
        #expect(UnitParser.unprintableCharacters("«Привет» é ok", manifest: manifest, set: set, library: Repo.library) == ["«", "»", "é"])
        #expect(SuiteBuilder.describe("ʼ") == "ʼ U+02BC")
    }

    @Test func theQuickCountNeverRejectsWhatTheFullCountKeeps() {
        for text in ["раз  два\tтри", "a\u{00A0}b c", "\u{E000}code\u{E001} x y", "- - слово", "  "] {
            #expect(UnitParser.quickTokenCount(text) >= UnitParser.tokens(of: UnitParser.keyboard(text)).count)
        }
    }

    @Test func codeMarksTagTheTokensInsideAndAreTakenOff() {
        let tokens = UnitParser.tokens(of: "вызови \u{E000}foo bar()\u{E001}, потом")
        #expect(tokens.map(\.text) == ["вызови", "foo", "bar(),", "потом"])
        #expect(tokens.map(\.code) == [false, true, true, false])
    }

    @Test func lowerCaseAndNoMarksMakeAChatLine() throws {
        let unit = try parse("Привет, Мир! Это «ТЕСТ»: don't stop - ok?", extra: ",\"transform\":[\"lowercase\",\"stripPunctuation\"]").get()
        #expect(unit.tokens.map(\.text) == ["привет", "мир", "это", "тест", "don't", "stop", "ok"])
        #expect(UnitParser.stripPunctuation("кто-то, где-нибудь -") == "кто-то где-нибудь ")
    }
}

extension Result where Failure == Drop {
    func isFailure(_ drop: Drop) -> Bool {
        if case let .failure(found) = self { found == drop } else { false }
    }
}

@Suite struct ScenarioTests {
    let manifest = try! SuiteFixtures.manifest(scenarios: SuiteManifest.scenarioNames)
    let set = try! LayoutSet(names: ["ABC", "Russian"], library: Repo.library)
    let sentence = "давай созвонимся в zoom и обсудим"

    func unit(_ text: String? = nil) throws -> ParsedUnit {
        try UnitParser.parse(text ?? sentence, filter: nil, set: set, library: Repo.library).get()
    }

    func warmup(_ text: String = "I will check it tomorrow", script: LetterScript = .latin) throws -> Warmup {
        Warmup(unit: try UnitParser.parse(text, filter: nil, set: set, library: Repo.library).get(), script: script)
    }

    func build(_ scenario: String, _ text: String? = nil, warmup: Warmup? = nil, manifest: SuiteManifest? = nil) throws -> EvalCase {
        let builder = ScenarioBuilder(manifest: manifest ?? self.manifest, library: Repo.library)
        return try builder.build(ref: "t:1", unit: try unit(text), scenario: scenario, warmup: warmup).get()
    }

    @Test func cleanColdChoosesTheLayoutBeforeEachChangeOfLanguage() throws {
        let item = try build("clean.cold")
        #expect(item.start == "Russian")
        #expect(item.script == [.type("давай созвонимся в ", on: "Russian"), .layout("ABC"), .type("zoom ", on: "ABC"),
                                .layout("Russian"), .type("и обсудим ", on: "Russian")])
        #expect(item.tokens?.map(\.err) == Array(repeating: .none, count: 6))
        #expect(item.tokens?.map(\.lang) == ["ru", "ru", "ru", "en", "ru", "ru"])
        #expect(item.want == sentence)
        #expect(item.tags == ["mixed"])
    }

    @Test func slipColdStartsOnTheWrongLayoutAndChoosesAfterTheFirstChange() throws {
        let item = try build("slip.cold")
        #expect(item.start == "ABC")
        #expect(item.script.first == .type("давай созвонимся в ", on: "Russian"))
        #expect(item.script.contains(.layout("ABC")))
        #expect(item.tokens?.map(\.err) == [.layout, .layout, .layout, .none, .none, .none])
    }

    @Test func slipWarmStartsOnTheLayoutOfTheWarmUp() throws {
        let item = try build("slip.warm", warmup: try warmup())
        #expect(item.start == "ABC")
        #expect(item.warmup == [.type("I will check it tomorrow ", on: "ABC")])
        #expect(item.script.first == .type("давай созвонимся в ", on: "Russian"))
        #expect(item.want == "I will check it tomorrow " + sentence)
        #expect(item.tokens?.map(\.err).prefix(3).allSatisfy { $0 == .layout } == true)
    }

    @Test func cleanWarmChoosesTheLayoutAfterTheWarmUp() throws {
        let item = try build("clean.warm", warmup: try warmup())
        #expect(item.start == "ABC")
        #expect(item.script.first == .layout("Russian"))
        #expect(item.tokens?.allSatisfy { $0.err == .none } == true)
    }

    @Test func stuckNeverTouchesTheLayoutAndTheTokensOfTheOtherLayoutAreWrong() throws {
        let item = try build("stuck")
        #expect(item.start == "Russian")
        #expect(item.script == [.type("давай созвонимся в ", on: "Russian"), .type("zoom ", on: "ABC"),
                                .type("и обсудим ", on: "Russian")])
        #expect(item.tokens?.map(\.err) == [.none, .none, .none, .layout, .none, .none])
    }

    @Test func cleanToggleUsesTheShortcutAndNullFollowsIt() throws {
        let item = try build("clean.toggle")
        #expect(item.script == [.type("давай созвонимся в ", on: "Russian"), .hotkey(.switchLayout), .type("zoom ", on: "ABC"),
                                .hotkey(.switchLayout), .type("и обсудим ", on: "Russian")])
        #expect(item.tokens?.allSatisfy { $0.err == .none } == true)
    }

    @Test func aMixedTokenGetsALayoutStepInsideAndEveryCaseHoldsUp() throws {
        let item = try build("clean.cold", "это USB-порт здесь")
        #expect(item.script.contains(.layout("ABC")))
        #expect(item.tokens?[1].tags == ["mixed-token"])
        #expect(item.tokens?[1].lang == "en")
        for scenario in SuiteManifest.scenarioNames {
            let built = try build(scenario, warmup: try warmup())
            #expect(CaseCheck.problems(built, layouts: Repo.library).isEmpty, "\(scenario)")
            #expect(built.id == (try built.computedID()))
        }
    }

    @Test func aSentenceInOneScriptHasNoStuckAndNoToggle() throws {
        let builder = ScenarioBuilder(manifest: manifest, library: Repo.library)
        for scenario in ["stuck", "clean.toggle"] {
            let result = try builder.build(ref: "t:1", unit: try unit("раз два три"), scenario: scenario, warmup: nil)
            #expect(result.isFailure(.singleScript))
        }
        #expect(try builder.build(ref: "t:1", unit: try unit("раз два три"), scenario: "clean.warm", warmup: nil).isFailure(.noWarmup))
    }

    @Test func theCaseEndsAsTheManifestSays() throws {
        let returned = try build("clean.cold", "раз два три", manifest: try SuiteFixtures.manifest(extra: ",\"end\":\"return\""))
        #expect(returned.script == [.type("раз два три", on: "Russian"), .key(.return, n: nil, mods: nil)])
        let bare = try build("clean.cold", "раз два три", manifest: try SuiteFixtures.manifest(extra: ",\"end\":\"none\""))
        #expect(bare.script == [.type("раз два три", on: "Russian")])
    }

    @Test func theOracleIsExactOnEveryBuiltCaseAndTheTextIsWhatTheTokensSay() throws {
        for scenario in SuiteManifest.scenarioNames {
            let played = try Cases.play(try build(scenario, warmup: try warmup()), system: .oracle)
            #expect(played.score.exact, "\(scenario)")
        }
    }

    @Test func errIsWhereNullIsWrongAsTheScorerSaysIt() throws {
        for scenario in SuiteManifest.scenarioNames {
            let item = try build(scenario, "это USB-порт и zoom, потом git push", warmup: try warmup())
            let played = try Cases.play(item, system: .null)
            let wrong = played.score.measured.map { $0.outcome != .ok }
            #expect(item.tokens?.map { $0.err == .layout } == wrong, "\(scenario)")
        }
    }

    @Test func theSettingsOfTheManifestGoIntoTheEnv() throws {
        let item = try build("clean.cold", "раз два три", manifest: try SuiteFixtures.manifest(extra: ",\"settings\":\"all\""))
        #expect(item.env?.settings == "all")
        #expect(try build("clean.cold", "раз два три").env == nil)
    }
}

@Suite struct SplitTests {
    @Test func theHashDecidesAndTheShareIsTheManifests() {
        var dev = 0
        for index in 0..<10000 where ScenarioBuilder.split(suite: "s", key: "ref\(index)", dev: 20) == .dev { dev += 1 }
        #expect(abs(dev - 2000) < 150)
        #expect(ScenarioBuilder.split(suite: "s", key: "ref1", dev: 0) == .test)
        #expect(ScenarioBuilder.split(suite: "s", key: "ref1", dev: 100) == .dev)
        // The definition, with a number fixed so that a change of the hash shows.
        #expect(FNV1a.hash64("s\u{1F}ref1") % 100 == 63)
        #expect(ScenarioBuilder.split(suite: "s", key: "ref1", dev: 64) == .dev)
        #expect(ScenarioBuilder.split(suite: "s", key: "ref1", dev: 63) == .test)
    }

    @Test func theRankDependsOnTheSeedAndTheEpochOnly() {
        #expect(SuiteBuilder.rank(ref: "a", seed: 1, epoch: 1) == SuiteBuilder.rank(ref: "a", seed: 1, epoch: 1))
        #expect(SuiteBuilder.rank(ref: "a", seed: 1, epoch: 1) != SuiteBuilder.rank(ref: "a", seed: 1, epoch: 2))
        #expect(SuiteBuilder.rank(ref: "a", seed: 1, epoch: 1) == SuiteBuilder.rank(ref: "a", seed: 0, epoch: 2))
        #expect(SuiteBuilder.rank(ref: "a", seed: 1, epoch: 1) != SuiteBuilder.rank(ref: "b", seed: 1, epoch: 1))
    }
}

@Suite struct SuiteBuilderTests {
    func build(_ manifest: SuiteManifest, cache: String, tier: SuiteManifest.Tier = .ci) throws -> SuiteBuilder.Output {
        try SuiteBuilder(manifest: manifest, library: Repo.library).build(tier: tier, cache: cache)
    }

    @Test func twoBuildsGiveTheSameBytes() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 300, extra: ",\"filter\":{\"minTokens\":8}")
        let first = try build(manifest, cache: cache), second = try build(manifest, cache: cache)
        #expect(try CaseCodec.write(first.cases) == CaseCodec.write(second.cases))
        #expect(first.report == second.report)
        #expect(!first.cases.isEmpty)
    }

    @Test func everyScenarioGetsItsTokensAndNoMoreThanOneCaseOver() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 300, extra: ",\"filter\":{\"minTokens\":8}")
        let output = try build(manifest, cache: cache)
        for scenario in manifest.scenarios {
            let stats = try #require(output.report.scenarios[scenario])
            #expect(stats.tokens >= 300 && stats.tokens < 300 + 12, "\(scenario) \(stats.tokens)")
            #expect(stats.shortfall == 0)
            #expect(stats.cases == output.cases.filter { $0.scenario == scenario }.count)
        }
    }

    @Test func allScenariosOfAUnitFallInOnePartAndTheCasesPassTheCheck() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 300, extra: ",\"filter\":{\"minTokens\":8}")
        let output = try build(manifest, cache: cache)
        var parts: [String: Set<EvalCase.Split>] = [:]
        for item in output.cases {
            parts[item.meta?["ref"]?.string ?? "", default: []].insert(item.split)
            #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty)
        }
        #expect(parts.values.allSatisfy { $0.count == 1 })
        #expect(output.cases.contains { $0.split == .dev } && output.cases.contains { $0.split == .test })
    }

    @Test func theFilesOfASourceWeighTheSame() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 200, extra: ",\"filter\":{\"minTokens\":8}")
        let output = try build(manifest, cache: cache)
        let refs = output.cases.filter { $0.scenario == "clean.cold" }.compactMap { $0.meta?["ref"]?.string }
        let russian = refs.filter { $0.contains("rus") }.count
        #expect(russian > 0 && russian < refs.count)
        #expect(abs(russian - (refs.count - russian)) <= refs.count / 5, "\(russian) of \(refs.count)")
        #expect(SuiteBuilder.interleaved([[1, 2, 3], [10], [20, 21]]) == [1, 10, 20, 2, 21, 3])
    }

    @Test func aSmallFileLimitsTheOthersUnlessBalanceIsOff() throws {
        let cache = try SuiteFixtures.tatoebaCache(count: 60, englishCount: 600)
        func english(_ extra: String) throws -> Int {
            let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 100_000,
                                                      extra: ",\"filter\":{\"minTokens\":8}" + extra)
            let refs = try build(manifest, cache: cache).cases.filter { $0.scenario == "clean.cold" }
                .compactMap { $0.meta?["ref"]?.string }
            return refs.filter { $0.contains("eng") }.count
        }
        let balanced = try english(""), free = try english(",\"balance\":false")
        #expect(balanced <= 60)
        #expect(free > balanced)
    }

    @Test func aNewEpochTakesOtherUnits() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        var manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 100, extra: ",\"filter\":{\"minTokens\":8}")
        let one = Set(try build(manifest, cache: cache).cases.compactMap { $0.meta?["ref"]?.string })
        manifest.epoch = 2
        let two = Set(try build(manifest, cache: cache).cases.compactMap { $0.meta?["ref"]?.string })
        #expect(one != two)
        #expect(one.intersection(two).count < one.count)
        #expect(try build(manifest, cache: cache).cases.allSatisfy { $0.epoch == 2 })
    }

    @Test func aSourceThatRunsOutReportsTheShortfall() throws {
        let cache = try SuiteFixtures.tatoebaCache(count: 5)
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 100_000, extra: ",\"filter\":{\"minTokens\":8}")
        let output = try build(manifest, cache: cache)
        #expect(output.report.scenarios["clean.cold"]?.shortfall ?? 0 > 0)
        #expect(output.report.units == 10)
    }

    @Test func theReasonsAreCountedAndNoWordIsInTheReport() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, tier: 300, extra: ",\"filter\":{\"minTokens\":11}")
        let output = try build(manifest, cache: cache)
        #expect(output.report.drops["tooShort", default: 0] > 0)
        let json = try CaseCodec.json(output.report)
        for word in SuiteFixtures.russianWords + SuiteFixtures.englishWords where word.count > 3 {
            #expect(!json.contains(word))
        }
    }

    @Test func monoScriptSuitesSkipStuckAndToggle() throws {
        let cache = try SuiteFixtures.tatoebaCache()
        let manifest = try SuiteFixtures.manifest(source: SuiteFixtures.tatoeba, scenarios: SuiteManifest.scenarioNames, tier: 100,
                                                  extra: ",\"filter\":{\"minTokens\":8}")
        let output = try build(manifest, cache: cache)
        #expect(output.report.scenarios["stuck"]?.cases == 0)
        #expect(output.report.scenarios["stuck"]?.drops["singleScript"] ?? 0 > 0)
        #expect(output.report.scenarios["stuck"]?.shortfall == 100)
        #expect(output.report.scenarios["clean.cold"]?.shortfall == 0)
    }

    @Test func aStackExchangeSourceBuildsMixedScenarios() throws {
        let cache = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: cache + "/se", withIntermediateDirectories: true)
        var rows = "<posts>\r\n"
        for index in 1...150 {
            let ru = SuiteFixtures.russianWords.dropFirst(index % 7).prefix(4).joined(separator: " ")
            let en = SuiteFixtures.englishWords.dropFirst(index % 5).prefix(3).joined(separator: " ")
            rows += " <row Id=\"\(index)\" Body=\"&lt;p&gt;Мы используем \(ru) через \(en) сегодня. And we use \(en).&lt;/p&gt;\" />\r\n"
        }
        rows += "</posts>\r\n"
        try rows.write(toFile: cache + "/se/Posts.xml", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/tar", ["--format", "7zip", "-cf", "x.7z", "Posts.xml"], in: cache + "/se")
        let manifest = try SuiteFixtures.manifest(reader: "stackexchange", source: "se/x.7z", scenarios: SuiteManifest.scenarioNames,
                                                  tier: 60, extra: ",\"filter\":{\"minTokens\":3,\"requireScripts\":[\"cyrillic\"]}")
        let output = try build(manifest, cache: cache)
        for scenario in SuiteManifest.scenarioNames { #expect((output.report.scenarios[scenario]?.cases ?? 0) > 0, "\(scenario)") }
        #expect(output.cases.allSatisfy { $0.meta?["source"]?.string == "x" })
        #expect(output.cases.allSatisfy { $0.tags?.contains("mixed") == true })
    }
}
