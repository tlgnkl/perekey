// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyModelKit
@testable import PerekeyEvalKit
import Testing

/// Manifests, sources and sentences of the correction suites' tests.
enum CorrectionFixtures {
    static func manifest(_ name: String, kind: String, scenarios: [String] = ["fix"], weights: String? = nil,
                         reader: String = "tatoeba", source: String = "tatoeba/rus_sentences.tsv.bz2,tatoeba/eng_sentences.tsv.bz2",
                         settings: String = "all", extra: String = "", tier: Int = 200) throws -> SuiteManifest
    {
        let list = scenarios.map { "\"\($0)\"" }.joined(separator: ",")
        let correction = "{\"kind\":\"\(kind)\"" + (weights.map { ",\"weights\":\($0)" } ?? "") + "}"
        let json = """
        {"suite":"\(name)","version":1,"epoch":1,"seed":3,"about":"test","reader":"\(reader)","source":"\(source)",
         "license":"test","sampling":"token","layoutSets":[["ABC","Russian"]],"scenarios":[\(list)],
         "settings":"\(settings)","tiers":{"ci":\(tier),"full":\(tier * 2)},"split":{"dev":20,"by":"unit"},
         "filter":{"minTokens":1,"maxTokens":40},"correction":\(correction)\(extra)}
        """
        return try JSONDecoder().decode(SuiteManifest.self, from: Data(json.utf8))
    }

    static let equal = "{\"neighbor\":20,\"swap\":20,\"drop\":20,\"double\":20,\"stray\":20}"

    /// A Tatoeba cache with these sentences, `rus` and `eng`.
    static func cache(rus: [String], eng: [String]) throws -> String {
        let cache = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: cache + "/tatoeba", withIntermediateDirectories: true)
        for (code, sentences) in [("rus", rus), ("eng", eng)] {
            let text = sentences.enumerated().map { "\($0.offset + 1)\t\(code)\t\($0.element)" }.joined(separator: "\n") + "\n"
            let file = "\(cache)/tatoeba/\(code)_sentences.tsv"
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            try SuiteFixtures.run("/usr/bin/bzip2", ["-f", file], in: cache)
        }
        return cache
    }

    /// Enough sentences of each shape for a build to find what it needs.
    static let russian = [
        "Я всё это знаю, но ничего не скажу.", "Он пришёл домой поздно вечером.", "Мы поедем куда-нибудь завтра утром.",
        "Что-то случилось с нашей машиной сегодня.", "Она живёт в Москве уже десять лет.",
        "Это моя любимая книга о путешествиях.", "Том работает в ООО на другом конце города.",
        "Он сказал, что был в МВД вчера днём.", "Давай встретимся где-то около пяти часов.",
        "Мария читает интересную книгу каждый вечер.", "Ёлка стоит посреди комнаты уже неделю.",
        "Мой брат учится в университете очень далеко.", "Погода сегодня была просто чудесная.",
        "Они вернулись из поездки по-прежнему весёлыми.", "Завтра я позвоню тебе после работы обязательно.",
    ]
    static let english = [
        "The weather was very nice yesterday afternoon.", "Tom works for the FBI in a big city.",
        "She bought a new iPhone last week in Boston.", "We will meet at the station tomorrow morning.",
        "I received your letter and I believe it.", "My brother studies at the university far away.",
        "They watched TV together every single evening.", "Please bring your passport and your ticket tomorrow.",
        "He told me about the project this morning.", "Mary reads an interesting book every evening.",
    ]

    static func build(_ manifest: SuiteManifest, cache: String) throws -> SuiteBuilder.Output {
        try CorrectionBuilder(manifest: manifest, library: Repo.library).build(tier: .ci, cache: cache)
    }

    static func parsed(_ text: String) throws -> ParsedUnit {
        let set = try LayoutSet(names: ["ABC", "Russian"], library: Repo.library)
        let manifest = try SuiteFixtures.manifest()
        guard case let .success(unit) = UnitParser.parse(text, manifest: manifest, set: set, library: Repo.library) else {
            throw EvalError.input("cannot parse \(text)")
        }
        return unit
    }
}

@Suite struct CorrectionManifestTests {
    @Test func aCorrectionSuiteListsItsOwnScenariosOnly() throws {
        #expect(try CorrectionFixtures.manifest("yo", kind: "yo", scenarios: ["fix"]).problems().isEmpty)
        #expect(try CorrectionFixtures.manifest("hyphen", kind: "hyphen", scenarios: ["fix.merged", "fix.spaced", "keep"])
            .problems().isEmpty)
        #expect(try CorrectionFixtures.manifest("yo", kind: "yo", scenarios: ["clean.cold"]).problems()
            .contains("unknown scenario clean.cold"))
        #expect(try CorrectionFixtures.manifest("yo", kind: "yo", scenarios: ["keep"]).problems()
            .contains("unknown scenario keep"))
        // A corpus suite may not list a correction scenario.
        #expect(try SuiteFixtures.manifest(scenarios: ["fix"]).problems().contains("unknown scenario fix"))
    }

    @Test func typoSynthNeedsWeightsThatAddUpToAHundred() throws {
        #expect(try CorrectionFixtures.manifest("t", kind: "typo.synth", weights: CorrectionFixtures.equal).problems().isEmpty)
        #expect(try !CorrectionFixtures.manifest("t", kind: "typo.synth").problems().isEmpty)
        let bad = "{\"neighbor\":50,\"swap\":20,\"drop\":20,\"double\":20,\"stray\":20}"
        #expect(try !CorrectionFixtures.manifest("t", kind: "typo.synth", weights: bad).problems().isEmpty)
        #expect(try !CorrectionFixtures.manifest("t", kind: "yo", weights: CorrectionFixtures.equal).problems().isEmpty)
    }

    @Test func realTyposGoWithAPairsReaderAndOnlyWithIt() throws {
        let real = try CorrectionFixtures.manifest("t", kind: "typo.real", reader: "misspellings", source: "x.txt")
        #expect(real.problems().isEmpty)
        #expect(try !CorrectionFixtures.manifest("t", kind: "typo.real").problems().isEmpty)
        #expect(try !CorrectionFixtures.manifest("t", kind: "yo", reader: "typopairs", source: "x.tsv").problems().isEmpty)
        #expect(try !CorrectionFixtures.manifest("t", kind: "typo.real", reader: "typopairs", source: "x.tsv",
                                                 extra: ",\"carrier\":\"a\"").problems().isEmpty)
    }

    @Test func aCorrectionManifestWritesAndReadsBack() throws {
        let manifest = try CorrectionFixtures.manifest("t", kind: "typo.synth", weights: CorrectionFixtures.equal)
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(SuiteManifest.self, from: data) == manifest)
    }

    @Test func theManifestsOfTheRepositoryRead() throws {
        let manifests = try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
        let names = Set(manifests.map(\.suite))
        for name in ["typos.synth.equal", "typos.synth.neighbor", "typos.synth.swap", "typos.none", "yo", "hyphen",
                     "doublecap", "capslock", "abbrev", "typos.real.en"]
        {
            #expect(names.contains(name), "no manifest \(name)")
        }
        let local = try SuiteManifestFiles.read(directory: Repo.path("eval/local"))
        #expect(local.map(\.suite) == ["typos.real.ru"])
    }

    @Test func theSyntheticSuitesDifferInTheirWeightsAndNotInTheCorrectorsOwn() throws {
        let corrector = SuiteManifest.TypoWeights(neighbor: 40, swap: 20, drop: 20, double: 10, stray: 10)
        let manifests = try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
            .filter { $0.suite.hasPrefix("typos.synth.") }
        let weights = manifests.compactMap { $0.correction?.weights }
        #expect(weights.count == 3)
        #expect(Set(weights).count == 3)
        #expect(!weights.contains(corrector))
        #expect(weights.contains { $0.neighbor == 70 })
        #expect(weights.contains { $0.swap == 50 })
        #expect(weights.contains { Set([$0.neighbor, $0.swap, $0.drop, $0.double, $0.stray]).count == 1 })
    }
}

@Suite struct TypoMakerTests {
    @Test func neighboursAreTheKeysAroundInTheRowsOfTheLayout() {
        #expect(Set(TypoMaker.neighbours(of: "s", language: "en")) == ["a", "d", "w", "e", "z", "x"])
        #expect(Set(TypoMaker.neighbours(of: "ы", language: "ru")).isSuperset(of: ["ф", "в", "ц", "у"]))
        #expect(TypoMaker.neighbours(of: "S", language: "en").contains("a"))
        #expect(TypoMaker.neighbours(of: "1", language: "en").isEmpty)
    }

    @Test func eachKindOfSlipIsOneEditAndTheWordChanges() {
        var random = SplitMix64(seed: 5)
        var kinds = Set<TypoMaker.Kind>()
        for _ in 0..<400 {
            guard let made = TypoMaker.make(word: "привет", language: "ru", weights: .init(neighbor: 20, swap: 20, drop: 20, double: 20, stray: 20),
                                            random: &random)
            else { continue }
            kinds.insert(made.kind)
            #expect(made.typo != "привет")
            #expect(Knowledge.distance(Array("привет"), Array(made.typo)) == 1)
        }
        #expect(kinds == Set(TypoMaker.Kind.allCases))
    }

    @Test func theSharesFollowTheWeights() {
        var random = SplitMix64(seed: 11)
        let weights = SuiteManifest.TypoWeights(neighbor: 70, swap: 10, drop: 10, double: 5, stray: 5)
        var counts: [TypoMaker.Kind: Int] = [:]
        for _ in 0..<20000 { counts[TypoMaker.pick(weights, &random), default: 0] += 1 }
        #expect(abs(Double(counts[.neighbor] ?? 0) / 20000 - 0.70) < 0.02)
        #expect(abs(Double(counts[.swap] ?? 0) / 20000 - 0.10) < 0.02)
        #expect(abs(Double(counts[.stray] ?? 0) / 20000 - 0.05) < 0.02)
    }

    @Test func aShortWordOrAWordWithAMarkGetsNoSlip() {
        var random = SplitMix64(seed: 1)
        let weights = SuiteManifest.TypoWeights(neighbor: 20, swap: 20, drop: 20, double: 20, stray: 20)
        #expect(TypoMaker.make(word: "дом", language: "ru", weights: weights, random: &random) == nil)
        #expect(TypoMaker.make(word: "что-то", language: "ru", weights: weights, random: &random) == nil)
    }

    @Test func theSameDiceGiveTheSameSlip() {
        let weights = SuiteManifest.TypoWeights(neighbor: 20, swap: 20, drop: 20, double: 20, stray: 20)
        var a = SplitMix64(seed: 9)
        var b = SplitMix64(seed: 9)
        let first = TypoMaker.make(word: "hello", language: "en", weights: weights, random: &a)
        let second = TypoMaker.make(word: "hello", language: "en", weights: weights, random: &b)
        #expect(first?.typo == second?.typo)
    }
}

@Suite struct CorrectionEditTests {
    func edit(_ kind: SuiteManifest.Correction.Kind, _ text: String, scenario: String = "fix",
              language: String = "ru") throws -> Result<Edited, Drop>
    {
        var random = SplitMix64(seed: 2)
        return try CorrectionEdits.apply(kind, scenario: scenario, tokens: CorrectionFixtures.parsed(text).tokens,
                                         language: language,
                                         weights: .init(neighbor: 20, swap: 20, drop: 20, double: 20, stray: 20),
                                         random: &random)
    }

    @Test func yoIsTypedAsYe() throws {
        let edited = try edit(.yo, "Он пришёл домой, а Ёлка осталась.").get()
        #expect(edited.typed == ["Он", "пришел", "домой,", "а", "Елка", "осталась."])
        #expect(edited.tags.map { !$0.isEmpty } == [false, true, false, false, true, false])
        if case .success = try edit(.yo, "Он пришел домой.") { Issue.record("a sentence with no ё gave an edit") }
    }

    @Test func aHyphenIsLeftOutOrTypedAsASpace() throws {
        #expect(try edit(.hyphen, "Что-то случилось, по-прежнему.", scenario: "fix.merged").get().typed
            == ["Что-то", "случилось,", "по-прежнему."].map { $0.replacingOccurrences(of: "-", with: "") })
        #expect(try edit(.hyphen, "Что-то случилось, по-прежнему.", scenario: "fix.spaced").get().typed
            == ["Что то", "случилось,", "по прежнему."])
        // Kept as written; the tokens with a hyphen are still marked.
        let kept = try edit(.hyphen, "Что-то случилось.", scenario: "keep").get()
        #expect(kept.typed == ["Что-то", "случилось."])
        #expect(kept.tags[0] == ["hyphen"])
        // A dash on its own or a token with two hyphens is not a hyphenated word.
        if case .success = try edit(.hyphen, "Кто - то и кое-что-то.", scenario: "fix.merged") { Issue.record("not a word with one hyphen") }
    }

    @Test func aDoubleCapitalIsTypedOnATitleWordOfThreeLettersOrMore() throws {
        let edited = try edit(.doublecap, "Привет, мир и Москва!").get()
        let changed = zip(edited.typed, ["Привет,", "мир", "и", "Москва!"]).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(["ПРивет,", "МОсква!"].contains(changed[0].0))
        if case .success = try edit(.doublecap, "Я и он.") { Issue.record("no word to put a capital on") }
    }

    @Test func doubleCapitalsThatArePartOfTheWordAreKeptAsTheyAre() throws {
        let edited = try edit(.doublecap, "Он купил iPhone в ООО", scenario: "keep").get()
        #expect(edited.typed == ["Он", "купил", "iPhone", "в", "ООО"])
        #expect(edited.tags.map { !$0.isEmpty } == [false, false, true, false, true])
        if case .success = try edit(.doublecap, "Он купил книгу.", scenario: "keep") { Issue.record("nothing with two capitals") }
    }

    @Test func capsLockNeedsATitleWordFirst() throws {
        let edited = try edit(.capslock, "Привет, мир!").get()
        #expect(edited.typed == ["Привет,", "мир!"])
        #expect(edited.tags[0] == ["lead"])
        if case .success = try edit(.capslock, "привет, мир!") { Issue.record("a small first letter") }
        if case .success = try edit(.capslock, "Я иду.") { Issue.record("one letter first") }
    }

    @Test func anAbbreviationIsTypedInSmallLettersUnlessTheSentenceShouts() throws {
        #expect(try edit(.abbrev, "Он служил в МВД вчера.").get().typed == ["Он", "служил", "в", "мвд", "вчера."])
        #expect(try edit(.abbrev, "Он служил в МВД вчера.", scenario: "keep").get().typed == ["Он", "служил", "в", "МВД", "вчера."])
        if case .success = try edit(.abbrev, "ОСТАНОВИТЕСЬ в МВД!") { Issue.record("shouting is not an abbreviation") }
        if case .success = try edit(.abbrev, "Он пришёл домой.") { Issue.record("no abbreviation") }
    }

    @Test func aTypoGoesIntoOneWordOfFourLettersOrMore() throws {
        let edited = try edit(.typoSynth, "Он пришёл домой поздно.").get()
        let changed = zip(edited.typed, ["Он", "пришёл", "домой", "поздно."]).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(edited.tags.filter { !$0.isEmpty }.count == 1)
    }
}

@Suite struct CorrectionCaseCheckTests {
    @Test func theTargetOfACapsLockCaseIsInCapitals() throws {
        let item = Cases.make([.capsLock(true), .type("Привет мир ", on: "Russian")], want: "Привет мир", start: "Russian",
                              tokens: [TokenSpec(t: "Привет", lang: "ru", err: .caps), TokenSpec(t: "мир", lang: "ru", err: .caps)])
        #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty)
        #expect(TargetText.of(item).full == "ПРИВЕТ МИР ")
        // Caps Lock turned off again: the rest is as typed.
        let off = Cases.make([.capsLock(true), .type("Привет ", on: "Russian"), .capsLock(false), .type("мир ", on: "Russian")],
                             want: "Привет мир", start: "Russian",
                             tokens: [TokenSpec(t: "Привет", lang: "ru", err: .caps), TokenSpec(t: "мир", lang: "ru")])
        #expect(CaseCheck.problems(off, layouts: Repo.library).isEmpty)
    }

    @Test func aHyphenTypedAsASpaceMayCountOneTokenMore() throws {
        let item = Cases.make([.type("что то случилось ", on: "Russian")], want: "что-то случилось", start: "Russian",
                              tokens: [TokenSpec(t: "что-то", lang: "ru", err: .hyphen), TokenSpec(t: "случилось", lang: "ru")])
        #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty)
        // The letters must still be the same.
        let other = Cases.make([.type("что та случилось ", on: "Russian")], want: "что-то случилось", start: "Russian",
                               tokens: [TokenSpec(t: "что-то", lang: "ru", err: .hyphen), TokenSpec(t: "случилось", lang: "ru")])
        #expect(!CaseCheck.problems(other, layouts: Repo.library).isEmpty)
        // And without a hyphen error a different number of tokens is still a problem.
        let plain = Cases.make([.type("что то случилось ", on: "Russian")], want: "что-то случилось", start: "Russian",
                               tokens: [TokenSpec(t: "что-то", lang: "ru", err: .typo), TokenSpec(t: "случилось", lang: "ru")])
        #expect(!CaseCheck.problems(plain, layouts: Repo.library).isEmpty)
    }
}

@Suite struct CorrectionBuilderTests {
    func output(_ manifest: SuiteManifest, rus: [String] = CorrectionFixtures.russian,
                eng: [String] = CorrectionFixtures.english) throws -> SuiteBuilder.Output
    {
        try CorrectionFixtures.build(manifest, cache: CorrectionFixtures.cache(rus: rus, eng: eng))
    }

    /// Every case holds up under the check, the Oracle is exact, and Null is wrong exactly where `err` says.
    func expectSound(_ cases: [EvalCase], slips: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(!cases.isEmpty, sourceLocation: sourceLocation)
        for item in cases {
            #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty, "\(item.id)", sourceLocation: sourceLocation)
            #expect(try Cases.play(item, system: .oracle).score.exact, "\(item.id)", sourceLocation: sourceLocation)
            let null = try Cases.play(item, system: .null)
            let wrong = null.score.measured.map { $0.outcome != .ok }
            #expect(item.tokens?.map { $0.err != .none } == wrong, "\(item.id)", sourceLocation: sourceLocation)
            if slips, item.scenario != "keep" {
                #expect(wrong.contains(true), "\(item.id)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func typosGoIntoOneWordAndNullIsWrongOnlyThere() throws {
        let manifest = try CorrectionFixtures.manifest("typos.synth.equal", kind: "typo.synth",
                                                       weights: CorrectionFixtures.equal, tier: 40)
        let built = try output(manifest)
        try expectSound(built.cases)
        for item in built.cases {
            #expect(item.tokens?.filter { $0.err == .typo }.count == 1, "\(item.id)")
            #expect(item.env?.settings == "all")
        }
        #expect(Set(built.cases.compactMap { $0.tokens?.first { $0.err == .typo }?.lang }) == ["ru", "en"])
        #expect(built.report.scenarios["fix"]?.errors == built.cases.count)
    }

    @Test func twoBuildsGiveTheSameBytes() throws {
        let manifest = try CorrectionFixtures.manifest("typos.synth.equal", kind: "typo.synth", weights: CorrectionFixtures.equal, tier: 40)
        let cache = try CorrectionFixtures.cache(rus: CorrectionFixtures.russian, eng: CorrectionFixtures.english)
        let first = try CorrectionFixtures.build(manifest, cache: cache)
        let second = try CorrectionFixtures.build(manifest, cache: cache)
        #expect(try CaseCodec.write(first.cases) == CaseCodec.write(second.cases))
        #expect(first.report == second.report)
    }

    @Test func differentWeightsGiveDifferentSlipsOnTheSameSentences() throws {
        let cache = try CorrectionFixtures.cache(rus: CorrectionFixtures.russian, eng: CorrectionFixtures.english)
        var kinds: [Set<String>] = []
        for weights in ["{\"neighbor\":100,\"swap\":0,\"drop\":0,\"double\":0,\"stray\":0}",
                        "{\"neighbor\":0,\"swap\":0,\"drop\":100,\"double\":0,\"stray\":0}"]
        {
            let manifest = try CorrectionFixtures.manifest("t", kind: "typo.synth", weights: weights, tier: 60)
            let built = try CorrectionFixtures.build(manifest, cache: cache)
            kinds.append(Set(built.cases.flatMap { $0.tokens ?? [] }.flatMap { $0.tags ?? [] }))
        }
        #expect(kinds[0] == ["neighbor"])
        #expect(kinds[1] == ["drop"])
    }

    @Test func yoSentencesAreTypedWithYe() throws {
        let manifest = try CorrectionFixtures.manifest("yo", kind: "yo", source: "tatoeba/rus_sentences.tsv.bz2", tier: 40)
        let built = try output(manifest)
        try expectSound(built.cases)
        for item in built.cases {
            #expect(item.want.contains("ё") || item.want.contains("Ё"))
            #expect(!TargetText.of(item).full.lowercased().contains("ё"))
            #expect(item.tokens?.filter { $0.err == .yo }.allSatisfy { $0.t.lowercased().contains("ё") } == true)
        }
    }

    @Test func hyphenIsLeftOutTypedAsASpaceAndKept() throws {
        let manifest = try CorrectionFixtures.manifest("hyphen", kind: "hyphen", scenarios: ["fix.merged", "fix.spaced", "keep"],
                                                       source: "tatoeba/rus_sentences.tsv.bz2", tier: 20)
        let built = try output(manifest)
        for scenario in manifest.scenarios {
            let cases = built.cases.filter { $0.scenario == scenario }
            try expectSound(cases)
            #expect(!cases.isEmpty, "\(scenario)")
        }
        let merged = try #require(built.cases.first { $0.scenario == "fix.merged" })
        let spaced = try #require(built.cases.first { $0.scenario == "fix.spaced" })
        let kept = try #require(built.cases.first { $0.scenario == "keep" })
        #expect(!TargetText.of(merged).full.contains("-"))
        #expect(!TargetText.of(spaced).full.contains("-"))
        #expect(Tokenizer.tokens(TargetText.of(spaced).full).count > Tokenizer.tokens(spaced.want).count)
        #expect(kept.tokens?.allSatisfy { $0.err == .none } == true)
        #expect(TargetText.of(kept).full.trimmingCharacters(in: .whitespaces) == kept.want)
        // Null takes a hyphen word typed as two words for one wrong word, not two.
        let played = try Cases.play(spaced, system: .null)
        #expect(played.score.measured.filter { $0.outcome != .ok }.count == spaced.tokens?.filter { $0.err == .hyphen }.count)
    }

    @Test func doubleCapitalsAreTypedOnOneTitleWordAndKeptWhereTheyAreReal() throws {
        let manifest = try CorrectionFixtures.manifest("doublecap", kind: "doublecap", scenarios: ["fix", "keep"], tier: 30)
        let built = try output(manifest)
        let fix = built.cases.filter { $0.scenario == "fix" }
        let keep = built.cases.filter { $0.scenario == "keep" }
        try expectSound(fix)
        try expectSound(keep)
        for item in fix {
            #expect(item.tokens?.filter { $0.err == .doublecap }.count == 1)
            let bad = try #require(item.tokens?.first { $0.err == .doublecap })
            #expect(TargetText.of(item).full.contains(bad.t.prefix(2).uppercased()))
        }
        #expect(keep.allSatisfy { $0.tokens?.contains { $0.tags?.contains("capitals") == true } == true })
    }

    @Test func capsLockTypesTheWholeSentenceInCapitals() throws {
        let manifest = try CorrectionFixtures.manifest("capslock", kind: "capslock", tier: 30)
        let built = try output(manifest)
        try expectSound(built.cases)
        for item in built.cases {
            #expect(item.script.first == .capsLock(true))
            let lead = try #require(item.tokens?.first)
            #expect(lead.err == .caps && lead.tags == ["lead"])
            let null = try Cases.play(item, system: .null)
            #expect(null.out.text.trimmingCharacters(in: .whitespaces)
                == item.want.uppercased().trimmingCharacters(in: .whitespaces))
        }
    }

    @Test func abbreviationsAreTypedSmallAndKeptAsWritten() throws {
        let manifest = try CorrectionFixtures.manifest("abbrev", kind: "abbrev", scenarios: ["fix", "keep"], tier: 20)
        let built = try output(manifest)
        let fix = built.cases.filter { $0.scenario == "fix" }
        try expectSound(fix)
        try expectSound(built.cases.filter { $0.scenario == "keep" })
        for item in fix {
            for token in item.tokens ?? [] where token.err == .abbrev {
                #expect(TargetText.of(item).full.contains(token.t.lowercased()))
            }
        }
    }

    @Test func aSentenceWithNothingToCorrectIsCountedAndNotBuilt() throws {
        let manifest = try CorrectionFixtures.manifest("yo", kind: "yo", source: "tatoeba/rus_sentences.tsv.bz2", tier: 40)
        let built = try output(manifest, rus: ["Он пришел домой.", "Она ушла рано утром."], eng: ["Hello there my friend."])
        #expect(built.cases.isEmpty)
    }

    @Test func thePartIsDecidedByTheUnitAndTheTestPartIsThere() throws {
        let manifest = try CorrectionFixtures.manifest("hyphen", kind: "hyphen", scenarios: ["fix.merged", "fix.spaced", "keep"],
                                                       source: "tatoeba/rus_sentences.tsv.bz2", tier: 400)
        let built = try output(manifest, rus: (0..<80).map { "Что-то случилось с номером \($0) сегодня." })
        var parts: [String: Set<EvalCase.Split>] = [:]
        for item in built.cases { parts[item.meta?["ref"]?.string ?? "", default: []].insert(item.split) }
        #expect(parts.values.allSatisfy { $0.count == 1 })
        #expect(built.cases.contains { $0.split == .dev } && built.cases.contains { $0.split == .test })
    }
}

@Suite struct RealTypoTests {
    static let list = """
    # a comment
    beleive->believe
    recieve->receive
    definately->definitely
    accension->accession, ascension
    alot->a lot, allot
    teh->the
    adress->address
    Adress->address
    recieve->receive
    wierd->weird
    abc->xyz
    """

    @Test func onlyOneWordOneEditPairsAreKept() {
        let pairs = CorrectionBuilder.misspellings(in: Self.list)
        // teh -> the: the word is shorter than four letters; abc->xyz: three edits; two corrections and phrases: out.
        #expect(pairs.map(\.typo) == ["beleive", "recieve", "definately", "adress", "wierd"])
        #expect(pairs.first?.meant == "believe")
    }

    @Test func aTypoTakesTheCaseOfTheWord() {
        #expect(PairEdits.matchCase("beleive", like: "Believe") == "Beleive")
        #expect(PairEdits.matchCase("beleive", like: "BELIEVE") == "BELEIVE")
        #expect(PairEdits.matchCase("beleive", like: "believe") == "beleive")
    }

    func cache(list: String, eng: [String]) throws -> String {
        let cache = try CorrectionFixtures.cache(rus: ["Привет всем"], eng: eng)
        try FileManager.default.createDirectory(atPath: cache + "/wikipedia-misspellings", withIntermediateDirectories: true)
        try list.write(toFile: cache + "/wikipedia-misspellings/for-machines.txt", atomically: true, encoding: .utf8)
        return cache
    }

    func manifest() throws -> SuiteManifest {
        try CorrectionFixtures.manifest("typos.real.en", kind: "typo.real", reader: "misspellings",
                                        source: "wikipedia-misspellings/for-machines.txt",
                                        extra: ",\"carrier\":\"tatoeba/eng_sentences.tsv.bz2\"", tier: 30)
    }

    @Test func aTypoGoesIntoASentenceThatHasTheWordOrStandsAlone() throws {
        let built = try CorrectionFixtures.build(
            manifest(), cache: cache(list: Self.list, eng: ["I believe it was a nice day.", "Believe me, it is true."]))
        try CorrectionBuilderTests().expectSound(built.cases)
        let believe = built.cases.filter { $0.want.lowercased().contains("believe") }
        #expect(believe.count == 1)
        #expect(believe.contains { $0.want.contains(" ") })
        #expect(TargetText.of(believe[0]).full.lowercased().contains("beleive"))
        let alone = built.cases.filter { $0.tags?.contains("alone") == true }
        #expect(alone.count == 4)
        #expect(alone.allSatisfy { Tokenizer.tokens($0.want).count == 1 && $0.tokens?.first?.err == .typo })
    }

    @Test func aCarrierThatStartsWithTheWordKeepsItsCapital() throws {
        let built = try CorrectionFixtures.build(
            manifest(), cache: cache(list: "beleive->believe\n", eng: ["Believe me, it is true."]))
        let item = try #require(built.cases.first)
        #expect(TargetText.of(item).full == "Beleive me, it is true. ")
    }

    @Test func aFileOfThePersonIsReadAsPairs() throws {
        let manifest = try CorrectionFixtures.manifest(
            "typos.real.ru", kind: "typo.real", reader: "typopairs", source: "local/typos.real.ru.tsv",
            extra: ",\"tags\":[\"local\"]", tier: 30)
        let cache = try CorrectionFixtures.cache(rus: ["Привет"], eng: ["Hello"])
        try FileManager.default.createDirectory(atPath: cache + "/local", withIntermediateDirectories: true)
        let file = """
        # typo, meant
        превет\tпривет
        Я иду домой сегодня\tЯ иду домой сегодня
        Я иду дмой сегодня\tЯ иду домой сегодня
        Я иду дрмой сегодня\tЯ иду домой сегодня
        Я иду дмоой сегодня\tЯ иду домой сегодня
        Мы идем дом сегодня\tМы идем домой сегодня
        bad line without a tab
        """
        try file.write(toFile: cache + "/local/typos.real.ru.tsv", atomically: true, encoding: .utf8)
        let built = try CorrectionFixtures.build(manifest, cache: cache)
        try CorrectionBuilderTests().expectSound(built.cases)
        // Kept: the word pair and the three sentences with one edit (a letter dropped, a letter changed, two letters swapped);
        // out: the sentence with no difference, and «дом» for «домой» is two edits.
        #expect(built.cases.count == 4)
        #expect(built.report.drops["badLine"] == 1)
        #expect(built.cases.allSatisfy { $0.tags?.contains("local") == true })
    }
}
