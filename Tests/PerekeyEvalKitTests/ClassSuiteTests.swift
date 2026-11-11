// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// Helpers for the class suites: a lexicon of a few words, a manifest of a rule, a context over them.
enum ClassFixtures {
    static func lexiconDirectory(_ words: [String: [(String, Double)]]) throws -> String {
        let directory = try SuiteFixtures.directory()
        for (language, list) in words {
            let text = list.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
                .map { "\($0.0)\t\(String(format: "%.2f", $0.1))" }.joined(separator: "\n") + "\n"
            try text.write(toFile: "\(directory)/lexicon-\(language).tsv", atomically: true, encoding: .utf8)
        }
        return directory
    }

    static func manifest(_ name: String = "class.t", rule: String, classBody: String = "", scenarios: [String] = ["clean.cold"],
                         tier: Int = 100, layoutSets: String = "[[\"ABC\",\"Russian\"]]") throws -> SuiteManifest
    {
        let list = scenarios.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"suite":"\(name)","version":1,"epoch":1,"seed":3,"about":"test","reader":"class","source":"\(SuiteFixtures.tatoeba)",
         "license":"test","sampling":"type","layoutSets":\(layoutSets),"scenarios":[\(list)],
         "tiers":{"ci":\(tier),"full":\(tier * 10)},"split":{"dev":50,"by":"unit"},
         "class":{"rule":"\(rule)"\(classBody.isEmpty ? "" : "," + classBody)}}
        """
        return try JSONDecoder().decode(SuiteManifest.self, from: Data(json.utf8))
    }

    /// The rules of a manifest over a lexicon that has only the given words, no dictionary.
    static func rules(_ manifest: SuiteManifest, lexicon: [String: [(String, Double)]] = [:], classes: String? = nil,
                      tier: SuiteManifest.Tier = .ci) throws -> (ClassRules, ClassContext)
    {
        let directory = try lexiconDirectory(lexicon)
        let context = ClassContext(cache: directory, lexiconDirectory: directory, classesDirectory: classes ?? directory)
        for language in lexicon.keys { context.setDictionary(nil, for: language) }
        let sets = try manifest.layoutSets.map { try LayoutSet(names: $0, library: Repo.library) }
        let rules = ClassRules(manifest: manifest, spec: manifest.classSpec!, context: context, library: Repo.library,
                               sets: sets, tier: tier)
        return (rules, context)
    }

    static func texts(_ items: [ClassItem]) -> [String] { items.map(\.text) }
}

@Suite struct ClassManifestTests {
    @Test func theClassManifestsOfTheRepositoryReadAndTheirSeedsExist() throws {
        let manifests = try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
            .filter { $0.reader == .class }
        #expect(manifests.count >= 28)
        for manifest in manifests {
            #expect(manifest.problems().isEmpty)
            #expect(manifest.sampling == .type)
            for set in manifest.layoutSets { _ = try LayoutSet(names: set, library: Repo.library) }
            if let seeds = manifest.classSpec?.seeds {
                let list = try SeedList(path: Repo.path("eval/classes/\(seeds)"))
                #expect(!list.entries.isEmpty, "\(manifest.suite): empty seed list")
            }
        }
    }

    @Test func theUkrainianPairIsMadeOfManifestsAlone() throws {
        let manifests = Dictionary(uniqueKeysWithValues: try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
            .filter { $0.reader == .class }.map { ($0.suite, $0) })
        let pairs = manifests.keys.filter { $0.hasSuffix(".uk") }
        #expect(pairs.count >= 12)
        for name in pairs {
            let uk = manifests[name]!, ru = try #require(manifests[String(name.dropLast(3))], "no Russian twin of \(name)")
            #expect(uk.classSpec?.rule == ru.classSpec?.rule)
            #expect(uk.scenarios == ru.scenarios)
            #expect(uk.tiers == ru.tiers)
            #expect(uk.layoutSets.allSatisfy { $0.contains("Ukrainian-PC") } && ru.layoutSets.allSatisfy { !$0.contains("Ukrainian-PC") })
        }
    }

    @Test func theBigClassesTakeEveryWordFromZipfThreeAndOovReadsTheDumpOfTechRuso() throws {
        let manifests = Dictionary(uniqueKeysWithValues: try SuiteManifestFiles.read(directory: Repo.path("eval/suites"))
            .filter { $0.reader == .class }.map { ($0.suite, $0) })
        for name in ["class.short", "class.collision", "class.frequent", "class.short.uk", "class.collision.uk", "class.frequent.uk"] {
            #expect(manifests[name]?.classSpec?.requireDictionary == false, "\(name)")
        }
        for name in ["class.oov", "class.brands"] {
            let spec = try #require(manifests[name]?.classSpec)
            #expect(spec.corpusFiles == ["stackexchange/ru.stackoverflow.com.7z"] && spec.corpusFullFiles.isEmpty && spec.ciPosts != nil)
        }
        #expect(manifests["class.names.uk"]?.classSpec?.seeds == "class.names.uk.txt")
        #expect(manifests["class.names"]?.classSpec?.snapshot == "names.wikidata.tsv")
    }

    @Test func aClassManifestNeedsItsRule() throws {
        #expect(throws: DecodingError.self) { try ClassFixtures.manifest(rule: "nonsense") }
        let manifest = try ClassFixtures.manifest(rule: "short")
        #expect(manifest.problems().contains("class.languages is empty"))
        var other = try SuiteFixtures.manifest()
        other.classSpec = ClassSpec(rule: .short, languages: ["ru"], maxLetters: 2)
        #expect(other.problems().contains("class is for the class suites"))
        let json = try CaseCodec.json(ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"ru\"],\"maxLetters\":2"))
            .replacingOccurrences(of: "\"rule\"", with: "\"extra\":1,\"rule\"")
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SuiteManifest.self, from: Data(json.utf8)) }
    }

    @Test func aClassManifestWritesAndReadsBack() throws {
        let manifest = try ClassFixtures.manifest(rule: "oov", classBody: "\"languages\":[\"ru\"],\"corpus\":\"a,b\",\"minPerMillion\":20")
        let back = try JSONDecoder().decode(SuiteManifest.self, from: Data(CaseCodec.json(manifest).utf8))
        #expect(back == manifest)
    }
}

@Suite struct ClassLexiconRuleTests {
    static let lexicon: [String: [(String, Double)]] = [
        "ru": [("я", 6.4), ("мы", 6.0), ("да", 5.5), ("ну", 2.5), ("привет", 5.2), ("ъ", 1.0), ("ab", 4.0), ("ё", 3.2)],
        "en": [("a", 7.0), ("vs", 4.2), ("ok", 5.0), ("hello", 5.5), ("1a", 5.0), ("up", 3.0), ("we", 6.0)],
    ]

    @Test func shortTakesEveryWordOfOneOrTwoLettersFromZipfThree() throws {
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"ru\",\"en\"],\"maxLetters\":2")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: Self.lexicon)
        let items = try rules.short()
        // «ну» is under 3, «привет» is long, «ъ» is rare, «ab» is Latin in the Russian list, «1a» has a digit.
        #expect(Set(ClassFixtures.texts(items)) == ["я", "мы", "да", "ё", "a", "vs", "ok", "up", "we"])
        let weight = try #require(items.first { $0.text == "я" }).weight
        #expect(abs(weight - pow(10, 6.4 - 3)) < 1e-9)
        #expect(items.first { $0.text == "up" }?.weight == 1)
    }

    @Test func shortKeepsOnlyWordsOfTheDictionaryWhenThereIsOne() throws {
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"en\"],\"maxLetters\":2")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: Self.lexicon)
        context.setDictionary([Lexicon.key("a"), Lexicon.key("ok")], for: "en")
        #expect(Set(ClassFixtures.texts(try rules.short())) == ["a", "ok"])
    }

    @Test func collisionTakesWordsWhoseKeysTypeAFrequentWordInTheOtherLayout() throws {
        let manifest = try ClassFixtures.manifest(rule: "collision", classBody: "\"languages\":[\"ru\",\"en\"]")
        // «vs» on the keys of «мы»; «ok» is «щл», not a word; «да» is «lf» and «lf» is not in the list.
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: Self.lexicon)
        let items = try rules.collision()
        #expect(Set(ClassFixtures.texts(items)) == ["vs", "мы"])
    }

    @Test func collisionNeedsTheOtherWordToBeFrequentToo() throws {
        let manifest = try ClassFixtures.manifest(rule: "collision", classBody: "\"languages\":[\"ru\",\"en\"]")
        var lexicon = Self.lexicon
        lexicon["ru"] = [("мы", 2.9), ("я", 6.0)]
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: lexicon)
        #expect(try rules.collision().isEmpty)
    }

    @Test func frequentTakesTheTopOfEachLanguageByZipf() throws {
        let manifest = try ClassFixtures.manifest(rule: "frequent", classBody: "\"languages\":[\"ru\",\"en\"],\"top\":2,\"minZipf\":0")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: Self.lexicon)
        #expect(Set(ClassFixtures.texts(try rules.frequent())) == ["я", "мы", "a", "we"])
    }

    @Test func punctGivesEachWordOneDecorationAndKeepsTheWord() throws {
        var words: [(String, Double)] = []
        for index in 0..<200 { words.append(("слово" + String(UnicodeScalar(0x430 + UInt32(index % 32))!) + String(UnicodeScalar(0x430 + UInt32(index / 32))!), 4.0)) }
        let manifest = try ClassFixtures.manifest(rule: "punct", classBody: "\"languages\":[\"ru\"],\"top\":200",
                                                  layoutSets: "[[\"ABC\",\"Russian\"],[\"ABC\",\"RussianWin\"]]")
        let (_, context) = try ClassFixtures.rules(manifest, lexicon: ["ru": words])
        // Tatoeba rus: «по-новому» and «кто-то» are written often, «слово-ABC» mixes scripts, «а-б» is rare, «Кто-То» counts as «кто-то».
        var text = ""
        for index in 0..<6 { text += "\(index)\trus\tОн сделал это по-новому, а кто-то Кто-То слово-ABC.\n" }
        text += "9\trus\tСлово а-б и x-y.\n"
        let source = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: source + "/tatoeba", withIntermediateDirectories: true)
        try text.write(toFile: source + "/tatoeba/rus_sentences.tsv", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/bzip2", ["-f", source + "/tatoeba/rus_sentences.tsv"], in: source)
        let reading = ClassContext(cache: source, lexiconDirectory: context.lexiconDirectory, classesDirectory: source)
        reading.setDictionary(nil, for: "ru")
        let sets = [try LayoutSet(names: ["ABC", "Russian"], library: Repo.library), try LayoutSet(names: ["ABC", "RussianWin"], library: Repo.library)]
        let withCorpus = ClassRules(manifest: manifest, spec: manifest.classSpec!, context: reading, library: Repo.library, sets: sets, tier: .ci)
        let items = try withCorpus.punct()
        // 200 decorated words and the two hyphenated words of the corpus.
        #expect(items.count == 202)
        let hyphenated = items.filter { $0.tags.contains("punct:hyphen") }
        #expect(Set(ClassFixtures.texts(hyphenated)) == ["по-новому", "кто-то"])
        #expect(hyphenated.first { $0.text == "кто-то" }!.weight > hyphenated.first { $0.text == "по-новому" }!.weight)
        let kinds = Set(items.flatMap { $0.tags.filter { $0.hasPrefix("punct:") } })
        #expect(kinds == ["punct:lead", "punct:trail", "punct:both", "punct:hyphen"])
        for item in items where !item.tags.contains("punct:hyphen") {
            let decoration = ClassRules.decorations.first { item.text.hasPrefix($0.before) && item.text.hasSuffix($0.after) }
            #expect(decoration != nil, "\(item.text)")
            #expect(item.text.contains("слово"))
        }
        // The same words give the same items.
        #expect(try withCorpus.punct() == items)
        // `'`, `[` and `]` have no key on RussianWin: a Russian word never gets them, an English one does.
        #expect(!items.contains { $0.text.contains("'") || $0.text.contains("[") || $0.text.contains("]") })
        var english: [(String, Double)] = []
        for index in 0..<200 { english.append(("word" + String(UnicodeScalar(0x61 + UInt32(index % 26))!) + String(UnicodeScalar(0x61 + UInt32(index / 26))!), 4.0)) }
        let latinManifest = try ClassFixtures.manifest(rule: "punct", classBody: "\"languages\":[\"en\"],\"top\":200")
        let (_, englishContext) = try ClassFixtures.rules(latinManifest, lexicon: ["en": english])
        try "1\teng\tA well-known case, a well-known day, well-known, well-known, well-known.\n".write(toFile: source + "/tatoeba/eng_sentences.tsv", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/bzip2", ["-f", source + "/tatoeba/eng_sentences.tsv"], in: source)
        let englishReading = ClassContext(cache: source, lexiconDirectory: englishContext.lexiconDirectory, classesDirectory: source)
        englishReading.setDictionary(nil, for: "en")
        let latin = ClassRules(manifest: latinManifest, spec: latinManifest.classSpec!, context: englishReading, library: Repo.library,
                               sets: [try LayoutSet(names: ["ABC", "Russian"], library: Repo.library)], tier: .ci)
        let marked = try latin.punct()
        #expect(marked.contains { $0.text.contains("[") } && marked.contains { $0.text.contains("'") })
    }

    @Test func capsMakesTitleCapitalsAndCamelCase() throws {
        var words: [(String, Double)] = []
        for index in 0..<200 { words.append(("word" + String(UnicodeScalar(0x61 + UInt32(index % 26))!) + String(UnicodeScalar(0x61 + UInt32(index / 26))!), 4.0)) }
        let manifest = try ClassFixtures.manifest(rule: "caps", classBody: "\"languages\":[\"en\"],\"top\":200")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: ["en": words])
        let (items, _) = try rules.caps()
        let forms = Dictionary(grouping: items, by: { $0.tags.first { $0.hasPrefix("caps:") } ?? "" })
        #expect(Set(forms.keys) == ["caps:title", "caps:upper", "caps:camel", "caps:pascal"])
        for item in forms["caps:title"] ?? [] { #expect(item.text.first!.isUppercase && item.text.dropFirst() == item.text.dropFirst().lowercased()) }
        for item in forms["caps:upper"] ?? [] { #expect(item.text == item.text.uppercased()) }
        for item in forms["caps:camel"] ?? [] { #expect(item.text.first!.isLowercase && item.text.contains { $0.isUppercase }) }
        for item in forms["caps:pascal"] ?? [] { #expect(item.text.first!.isUppercase && item.text.dropFirst().contains { $0.isUppercase }) }
    }

    @Test func capsTakesAcronymsFromTheCorpus() throws {
        let manifest = try ClassFixtures.manifest(rule: "caps", classBody: "\"languages\":[\"en\"],\"top\":1,\"corpus\":\"c\",\"minPerMillion\":100")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: ["en": [("word", 5)]])
        var stats = CorpusStats()
        stats.total = 10_000
        stats.capitals = ["NASA": 5, "USB": 2, "СССР": 9, "AB": 0]
        context.setCorpus(stats, file: "c")
        let (items, _) = try rules.caps()
        let acronyms = items.filter { $0.tags.contains("caps:acronym") }
        // 5 of 10 000 is 500 per million; 2 is 200, «СССР» is Cyrillic and the suite has no Cyrillic language.
        #expect(Set(ClassFixtures.texts(acronyms)) == ["NASA", "USB"])
        #expect(acronyms.first { $0.text == "NASA" }?.weight == 500)
    }

    @Test func translitFollowsGost779SystemBWithoutMarks() {
        #expect(ClassRules.transliterate("привет") == "privet")
        #expect(ClassRules.transliterate("щи") == "shhi")
        #expect(ClassRules.transliterate("ёж") == "yozh")
        #expect(ClassRules.transliterate("объём") == "obyom")
        #expect(ClassRules.transliterate("цвет") == "czvet")
        #expect(ClassRules.transliterate("хорошо") == "xorosho")
        #expect(ClassRules.transliterate("Ёлка") == "yolka")
        #expect(ClassRules.transliterate("съел") == "sel")
        #expect(ClassRules.transliterate("мышь") == "mysh")
        #expect(ClassRules.transliterate("юля") == "yulya")
    }

    @Test func translitTakesTheMostFrequentRussianWords() throws {
        let manifest = try ClassFixtures.manifest(rule: "translit", classBody: "\"top\":3,\"minZipf\":0")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: ["ru": [("привет", 5.2), ("я", 6.4), ("мы", 6.0), ("да", 5.5)]])
        #expect(ClassFixtures.texts(try rules.translit()) == ["ya", "my", "da"])
    }
}

@Suite struct ClassSeedTests {
    @Test func aSeedListHasCommentsAndGroups() {
        let list = SeedList(text: "# header\nщас\tslang # inline\n\nzoom\n  ща  \tslang\n")
        #expect(list.entries == [.init(word: "щас", group: "slang"), .init(word: "zoom", group: nil), .init(word: "ща", group: "slang")])
    }

    @Test func aSeedTheRuleFoundKeepsTheRulesWeightAndOthersGetTheLexiconOrTheLeastZipf() throws {
        let directory = try SuiteFixtures.directory()
        try "я\tshort\nщас\tslang\nzzz\n".write(toFile: directory + "/seeds.txt", atomically: true, encoding: .utf8)
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"ru\"],\"maxLetters\":2,\"seeds\":\"seeds.txt\"")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: ["ru": [("я", 6.4), ("щас", 4.0)], "en": []], classes: directory)
        let derived = try rules.short()
        let seeds = try rules.seedItems(derived: derived)
        #expect(seeds.map(\.text) == ["я", "щас", "zzz"])
        #expect(seeds[0].weight == derived[0].weight)
        #expect(abs(seeds[1].weight - 10) < 1e-9)
        #expect(abs(seeds[2].weight - 0.1) < 1e-9)
        #expect(seeds[1].tags == ["seed", "seed:slang"] && seeds[2].tags == ["seed"])
    }
}

@Suite struct ClassCorpusRuleTests {
    func stats(_ counts: [String: Int], total: Int) -> CorpusStats {
        var stats = CorpusStats()
        stats.total = total
        stats.cyrillic = counts
        return stats
    }

    @Test func oovTakesFrequentWordsTheDictionaryLacks() throws {
        let manifest = try ClassFixtures.manifest(rule: "oov", classBody: "\"languages\":[\"ru\"],\"corpus\":\"c\",\"minPerMillion\":20")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: ["ru": [("привет", 5)]])
        context.setDictionary([Lexicon.key("привет"), Lexicon.key("дом")], for: "ru")
        // 1 000 000 tokens: 25 is 25 per million.
        context.setCorpus(stats(["щас": 25, "привет": 400, "дом": 300, "хз": 19, "мердж": 40, "а": 90_000], total: 1_000_000), file: "c")
        let (items, _) = try rules.oov()
        // «а» is one letter and not in this dictionary: the rule needs two.
        #expect(Set(ClassFixtures.texts(items)) == ["щас", "мердж"])
        #expect(items.first { $0.text == "щас" }?.weight == 25)
    }

    @Test func oovForALanguageWithoutADictionaryUsesTheLexicon() throws {
        let manifest = try ClassFixtures.manifest(rule: "oov", classBody: "\"languages\":[\"uk\"],\"corpus\":\"c\",\"minPerMillion\":20",
                                                  layoutSets: "[[\"ABC\",\"Ukrainian-PC\"]]")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: ["uk": [("привіт", 4.0), ("дякс", 1.0)]])
        context.setCorpus(stats(["привіт": 50, "дякс": 50, "кринж": 50], total: 1_000_000), file: "c")
        #expect(Set(ClassFixtures.texts(try rules.oov().0)) == ["дякс", "кринж"])
    }

    @Test func brandsAreLatinWordsAmongCyrillicTextWithACapitalOrOutsideTheEnglishDictionary() throws {
        let manifest = try ClassFixtures.manifest(rule: "brands", classBody: "\"corpus\":\"c\",\"minPerMillion\":5")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: ["en": []])
        context.setDictionary([Lexicon.key("the"), Lexicon.key("apple")], for: "en")
        var stats = CorpusStats()
        stats.total = 1_000_000
        stats.latinAmongCyrillic = ["GitHub": 30, "the": 100, "Apple": 20, "zoom": 12, "iPhone": 3, "a": 50]
        context.setCorpus(stats, file: "c")
        let (items, _) = try rules.brands()
        // «the» is an English word in lower case; «Apple» has a capital; «zoom» is not a dictionary word; «iPhone» is rare.
        #expect(Set(ClassFixtures.texts(items)) == ["GitHub", "Apple", "zoom"])
    }

    @Test func aCorpusCountsTokensByKind() {
        var stats = CorpusStats()
        let sentence = UnitParser.tokens(of: "Мы запушили \u{E000}git\u{E001} в GitHub и ООО Ромашка, NASA!")
        stats.add(sentence: sentence)
        #expect(stats.total == 9)
        #expect(stats.cyrillic["запушили"] == 1 && stats.cyrillic["мы"] == 1 && stats.cyrillic["ромашка"] == 1)
        #expect(stats.latin["github"] == 1 && stats.latin["git"] == nil)
        #expect(stats.latinAmongCyrillic["GitHub"] == 1 && stats.latinAmongCyrillic["NASA"] == 1)
        #expect(stats.capitals == ["ООО": 1, "NASA": 1])
        stats.add(sentence: UnitParser.tokens(of: "We use GitHub at work"))
        #expect(stats.latinAmongCyrillic["GitHub"] == 1)
    }

    @Test func tldrExamplesGiveCommandsFlagsPathsAndWords() {
        let tokens = ClassRules.tldrTokens("git commit -m {{message}} && git push {{[-f|--force]}} origin ~/repo/a.txt")
        let kinds = Dictionary(grouping: tokens, by: \.1).mapValues { $0.map(\.0) }
        #expect(kinds["command"] == ["git", "git"])
        #expect(Set(kinds["flag"] ?? []) == ["-m", "-f", "--force"])
        #expect(Set(kinds["word"] ?? []) == ["commit", "push", "origin"])
        #expect(kinds["path"] == ["~/repo/a.txt"])
        #expect(ClassRules.tldrExample("`ls -l`") == "ls -l")
        #expect(ClassRules.tldrExample("- Create a file:") == nil)
        #expect(ClassRules.tldrTokens("curl {{https://example.com}}").map(\.0) == ["curl"])
        #expect(ClassRules.tldrTokens("tar --file={{a.tar}}").map(\.0) == ["tar", "--file="])
    }

    @Test func cliReadsThePagesOfAnArchive() throws {
        let cache = try SuiteFixtures.directory()
        let pages = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: pages + "/common", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: pages + "/windows", withIntermediateDirectories: true)
        try "# git commit\n\n> Commit.\n\n- Commit all:\n\n`git commit -a`\n".write(toFile: pages + "/common/git-commit.md", atomically: true, encoding: .utf8)
        try "# dir\n\n- List:\n\n`dir /b`\n".write(toFile: pages + "/windows/dir.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: pages + "/osx", withIntermediateDirectories: true)
        try "# say\n\n- Speak:\n\n`say {{hello}}`\n".write(toFile: pages + "/osx/say.md", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/zip", ["-qr", cache + "/tldr.zip", "common", "windows", "osx"], in: pages)
        let manifest = try ClassFixtures.manifest(rule: "cli", classBody: "\"corpus\":\"tldr.zip\"")
        let (rules, context) = try ClassFixtures.rules(manifest, lexicon: [:])
        let items = try ClassRules(manifest: manifest, spec: manifest.classSpec!, context: ClassContext(cache: cache, lexiconDirectory: cache, classesDirectory: cache),
                                   library: Repo.library, sets: rules.sets, tier: .ci).cli().0
        _ = context
        // The Windows page is not read; the heading `git commit` has a space and is not a command name; a platform
        // the archive lacks (`linux` here) is not an error.
        #expect(Set(ClassFixtures.texts(items)) == ["git", "commit", "-a", "say"])
    }

    @Test func codeSkipsCommentsAndCountsTokensPerMillion() throws {
        let cache = try SuiteFixtures.directory()
        let source = try SuiteFixtures.directory()
        let body = (["// let comment = 1", "func run() {", "    let value = run()", "    return value", "}", "# not swift"]).joined(separator: "\n")
        try body.write(toFile: source + "/a.swift", atomically: true, encoding: .utf8)
        try "let ключ = 1\n".write(toFile: source + "/b.swift", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/tar", ["-czf", cache + "/swift-x.tar.gz", "a.swift", "b.swift"], in: source)
        let manifest = try ClassFixtures.manifest(rule: "code", classBody: "\"corpus\":\"swift-x.tar.gz\",\"minPerMillion\":50000")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: [:])
        let items = try ClassRules(manifest: manifest, spec: manifest.classSpec!, context: ClassContext(cache: cache, lexiconDirectory: cache, classesDirectory: cache),
                                   library: Repo.library, sets: rules.sets, tier: .ci).code().0
        let tokens = Set(ClassFixtures.texts(items))
        #expect(tokens.contains("func") && tokens.contains("let") && tokens.contains("value") && tokens.contains("=") == false)
        #expect(!tokens.contains("comment") && !tokens.contains("ключ"))
        #expect(items.first { $0.text == "let" }?.tags == ["code", "code:swift"])
    }

    @Test func aCodeArchiveMustSayItsLanguage() throws {
        let cache = try SuiteFixtures.directory()
        try Data().write(to: URL(fileURLWithPath: cache + "/x.tar.gz"))
        let manifest = try ClassFixtures.manifest(rule: "code", classBody: "\"corpus\":\"x.tar.gz\"")
        let (rules, _) = try ClassFixtures.rules(manifest, lexicon: [:])
        let broken = ClassRules(manifest: manifest, spec: manifest.classSpec!, context: ClassContext(cache: cache, lexiconDirectory: cache, classesDirectory: cache),
                                library: Repo.library, sets: rules.sets, tier: .ci)
        #expect(throws: EvalError.self) { try broken.code() }
    }

    func geonames(_ rows: [(name: String, ascii: String, alternates: String)]) throws -> String {
        let cache = try SuiteFixtures.directory()
        let source = try SuiteFixtures.directory()
        let lines = rows.map { row in
            ["1", row.name, row.ascii, row.alternates, "0", "0", "P", "PPL", "RU", "", "", "", "", "", "100000", "", "", "Europe/Moscow", "2020-01-01"]
                .joined(separator: "\t")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: source + "/cities15000.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: cache + "/geonames", withIntermediateDirectories: true)
        try SuiteFixtures.run("/usr/bin/zip", ["-q", cache + "/geonames/cities15000.zip", "cities15000.txt"], in: source)
        return cache
    }

    @Test func namesComeFromGeoNamesAndTheSnapshot() throws {
        let cache = try geonames([("Moskva", "Moskva", "Moscow,Москва,Moskau,Масква"), ("Saint Petersburg", "Saint Petersburg", "Санкт-Петербург")])
        let snapshot = try SuiteFixtures.directory()
        try "# comment\nru\ten\tuk\tlinks\nИван\tIvan\t\t30\nШарон / Шерон\tSharon\tШерон\t20\n"
            .write(toFile: snapshot + "/names.tsv", atomically: true, encoding: .utf8)
        let manifest = try ClassFixtures.manifest(rule: "names", classBody: "\"languages\":[\"ru\",\"en\"],\"corpus\":\"geonames/cities15000.zip\",\"snapshot\":\"names.tsv\"")
        let directory = try ClassFixtures.lexiconDirectory(["ru": [("москва", 5), ("иван", 4)], "en": []])
        let context = ClassContext(cache: cache, lexiconDirectory: directory, classesDirectory: snapshot)
        context.setDictionary(nil, for: "ru")
        let sets = [try LayoutSet(names: ["ABC", "Russian"], library: Repo.library)]
        let rules = ClassRules(manifest: manifest, spec: manifest.classSpec!, context: context, library: Repo.library, sets: sets, tier: .ci)
        // Cities: the Latin name when it is one word; a Cyrillic alternative only when the Russian lexicon has it
        // («Масква» is Belarusian). «Санкт-Петербург» has a hyphen. The snapshot gives one-word names per language.
        #expect(Set(ClassFixtures.texts(try rules.names().0)) == ["Moskva", "Москва", "Иван", "Ivan", "Sharon"])
        #expect(throws: EvalError.self) { try ClassRules.snapshotLabels(path: snapshot + "/none.tsv") }
    }

    @Test func aCyrillicAlternativeIsAWordOfTheLanguageOnlyIfTheLanguageKnowsIt() throws {
        let cache = try geonames([("Odesa", "Odesa", "Odessa,Одесса,Одеса,Odesa")])
        let russian = try ClassFixtures.manifest(rule: "names", classBody: "\"languages\":[\"ru\"],\"corpus\":\"geonames/cities15000.zip\"")
        let ukrainian = try ClassFixtures.manifest(rule: "names", classBody: "\"languages\":[\"uk\"],\"corpus\":\"geonames/cities15000.zip\"",
                                                   layoutSets: "[[\"ABC\",\"Ukrainian-PC\"]]")
        let directory = try ClassFixtures.lexiconDirectory(["ru": [("одесса", 4)], "uk": [("одеса", 4)], "en": []])
        func names(_ manifest: SuiteManifest) throws -> Set<String> {
            let context = ClassContext(cache: cache, lexiconDirectory: directory, classesDirectory: directory)
            context.setDictionary(nil, for: "ru")
            context.setDictionary(nil, for: "uk")
            let sets = try manifest.layoutSets.map { try LayoutSet(names: $0, library: Repo.library) }
            return Set(ClassFixtures.texts(try ClassRules(manifest: manifest, spec: manifest.classSpec!, context: context,
                                                          library: Repo.library, sets: sets, tier: .ci).names().0))
        }
        // «Одеса» is not Russian, «Одесса» is not Ukrainian; on ci the Ukrainian suite has Ukrainian names.
        #expect(try names(russian) == ["Одесса"])
        #expect(try names(ukrainian) == ["Одеса"])
    }

    @Test func aCorpusDumpIsReadOnlyUpToItsPostsOnTheQuickTier() throws {
        let cache = try SuiteFixtures.directory()
        let source = try SuiteFixtures.directory()
        var xml = "<?xml version=\"1.0\"?>\n<posts>\n"
        for (index, word) in ["один", "два", "три", "четыре"].enumerated() {
            xml += "  <row Id=\"\(index + 1)\" Body=\"&lt;p&gt;\(word) слово.&lt;/p&gt;\" />\n"
        }
        try (xml + "</posts>\n").write(toFile: source + "/Posts.xml", atomically: true, encoding: .utf8)
        try SuiteFixtures.run("/usr/bin/tar", ["-cf", cache + "/dump.7z", "Posts.xml"], in: source)
        let context = ClassContext(cache: cache, lexiconDirectory: cache, classesDirectory: cache)
        let some = try context.corpus(files: ["dump.7z"], posts: 2)
        #expect(some.cyrillic["один"] == 1 && some.cyrillic["два"] == 1 && some.cyrillic["три"] == nil)
        let all = try context.corpus(files: ["dump.7z"])
        #expect(all.cyrillic["четыре"] == 1 && all.cyrillic["слово"] == 4)
        // The counts of the limited read are kept apart from the whole one.
        #expect(try context.corpus(files: ["dump.7z"], posts: 2).cyrillic["слово"] == 2)
    }
}

@Suite struct ClassGeneratorTests {
    func rules(_ rule: String, languages: String = "[\"en\",\"ru\"]", tier: Int = 400) throws -> ClassRules {
        let manifest = try ClassFixtures.manifest("protect.\(rule)", rule: rule, classBody: "\"languages\":\(languages)", tier: tier)
        var words: [(String, Double)] = []
        for index in 0..<300 { words.append(("hello" + String(UnicodeScalar(0x61 + UInt32(index % 26))!) + String(UnicodeScalar(0x61 + UInt32(index / 26))!), 4)) }
        var russian: [(String, Double)] = []
        for index in 0..<300 { russian.append(("привет" + String(UnicodeScalar(0x430 + UInt32(index % 26))!) + String(UnicodeScalar(0x430 + UInt32(index / 26))!), 4)) }
        return try ClassFixtures.rules(manifest, lexicon: ["en": words, "ru": russian]).0
    }

    @Test func aGeneratorIsDeterministicAndFillsTheTier() throws {
        for rule in ["url", "password", "captcha", "numbers"] {
            let first = try rules(rule).generated(), second = try rules(rule).generated()
            #expect(first == second, "\(rule)")
            #expect(first.count >= 300, "\(rule): \(first.count)")
            #expect(Set(first.map(\.key)).count == first.count)
        }
    }

    @Test func urlsHaveTheShapesOfTheOldGenerator() throws {
        let items = try rules("url").generated()
        #expect(items.contains { $0.text.hasPrefix("https://") } && items.contains { $0.text.hasPrefix("www.") }
            && items.contains { $0.text.contains("@") } && items.contains { $0.text.hasPrefix("~/") && $0.text.hasSuffix(".txt") }
            && items.contains { $0.text.contains("?id=") })
        // A Cyrillic address has no `@` and no `~`: no key for them on the Cyrillic layouts.
        #expect(!items.filter { $0.tags.contains("url:cyrillic") }.contains { $0.text.contains("@") || $0.text.contains("~") })
        // A Latin host gets no Cyrillic TLD.
        #expect(!items.filter { $0.tags.contains("url:latin") }.contains { $0.text.contains(".рф") })
        #expect(items.contains { $0.tags.contains("url:cyrillic") && $0.text.contains(".рф") })
    }

    @Test func passwordsComeInBothLayoutsAndOneKindIsARussianWordOnLatinKeys() throws {
        let items = try rules("password").generated()
        let latin = items.filter { $0.tags.contains("password:latin") }, cyrillic = items.filter { $0.tags.contains("password:cyrillic") }
        #expect(!latin.isEmpty && !cyrillic.isEmpty)
        #expect(latin.allSatisfy { $0.text.unicodeScalars.allSatisfy(\.isASCII) })
        #expect(cyrillic.allSatisfy { $0.text.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } })
        // «привет…» typed on Latin keys is «ghbdtn…».
        #expect(latin.contains { $0.tags.contains("password:word") && $0.text.hasPrefix("Ghbdtn") })
    }

    @Test func captchasAreFourToEightLettersOfOneAlphabet() throws {
        let items = try rules("captcha").generated()
        for item in items {
            #expect((4...8).contains(item.text.count))
            let scripts = Set(item.text.compactMap(LetterScript.of))
            #expect(scripts.count == 1)
        }
        #expect(items.contains { $0.tags.contains("captcha:cyrillic") } && items.contains { $0.tags.contains("captcha:latin") })
    }

    @Test func aCaptchaUsesOnlyLettersOfTheLanguagesLayout() throws {
        let manifest = try ClassFixtures.manifest("protect.captcha", rule: "captcha", classBody: "\"languages\":[\"uk\"]", tier: 200,
                                                  layoutSets: "[[\"ABC\",\"Ukrainian-PC\"]]")
        var words: [(String, Double)] = []
        for index in 0..<100 { words.append(("привіт" + String(UnicodeScalar(0x430 + UInt32(index % 26))!), 4)) }
        let rules = try ClassFixtures.rules(manifest, lexicon: ["uk": words]).0
        let items = try rules.generated()
        #expect(items.count == 200)
        #expect(!items.contains { $0.text.contains { "ыЫэЭ".contains($0) } })
        #expect(items.contains { $0.text.contains { "іїєґ".contains($0.lowercased()) } })
    }

    @Test func numbersCoverTheirKinds() throws {
        let items = try rules("numbers").generated()
        let kinds = Set(items.flatMap { $0.tags.filter { $0.hasPrefix("numbers:") } })
        for kind in ["time", "date", "unit", "glued", "unit:cyrillic", "sign", "percent", "decimal", "version", "size", "phone"] {
            #expect(kinds.contains("numbers:\(kind)"), "\(kind)")
        }
        #expect(items.contains { $0.aim == .cyrillic } && items.contains { $0.aim == .latin })
        for item in items where item.tags.contains("numbers:time") { #expect(item.text.count == 5 && item.text.dropFirst(2).first == ":") }
    }
}

@Suite struct ClassSuiteBuilderTests {
    func build(_ manifest: SuiteManifest, lexicon: [String: [(String, Double)]], classes: String? = nil,
               cache: String? = nil) throws -> SuiteBuilder.Output
    {
        let directory = try ClassFixtures.lexiconDirectory(lexicon)
        let context = ClassContext(cache: cache ?? directory, lexiconDirectory: directory, classesDirectory: classes ?? directory)
        for language in lexicon.keys { context.setDictionary(nil, for: language) }
        return try ClassSuiteBuilder(manifest: manifest, library: Repo.library, context: context).build(tier: .ci)
    }

    static let lexicon: [String: [(String, Double)]] = [
        "ru": [("я", 6.4), ("мы", 6.0), ("да", 5.5), ("в", 6.8), ("и", 6.9), ("не", 6.5), ("на", 6.4)],
        "en": [("a", 7.0), ("vs", 4.2), ("ok", 5.0), ("we", 6.0), ("up", 5.0), ("is", 7.0)],
    ]

    @Test func everyItemBecomesACaseInEveryScenarioWithItsWeightAndClasses() throws {
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"ru\",\"en\"],\"maxLetters\":2",
                                                  scenarios: ["clean.cold", "slip.cold"])
        let output = try build(manifest, lexicon: Self.lexicon)
        let items = 13
        #expect(output.cases.count == items * 2)
        for item in output.cases {
            #expect(item.tokens?.count == 1)
            let token = try #require(item.tokens?.first)
            #expect(token.w != nil && token.tags?.contains("short") == true)
            // Tags are in byte order: a Set would order them differently in every process.
            #expect(token.tags == token.tags?.sorted())
            #expect(item.id.hasPrefix("class.t/"))
            #expect(item.meta?["ref"]?.string == Lexicon.core(token.t).replacingOccurrences(of: "ё", with: "е"))
            // The slip puts the fingers on the other layout than the one in force; the clean one does not.
            #expect((item.scenario == "slip.cold") == (token.err == .layout))
        }
        let a = try #require(output.cases.first { $0.tokens?.first?.t == "я" && $0.scenario == "clean.cold" })
        #expect(abs((a.tokens?.first?.w ?? 0) - pow(10, 3.4)) < 1e-4)
        #expect(output.report.classes?.rule == "short" && output.report.classes?.derived == items)
        #expect(output.report.scenarios["slip.cold"]?.cases == items)
        for item in output.cases { #expect(try CaseCheck.problems(item, layouts: Repo.library).isEmpty) }
    }

    @Test func allScenariosOfAWordFallInOnePartAndThePartsAreHalfAndHalf() throws {
        var words: [(String, Double)] = []
        for index in 0..<600 { words.append(("w" + String(UnicodeScalar(0x61 + UInt32(index % 26))!) + String(UnicodeScalar(0x61 + UInt32(index / 26))!), 5)) }
        let manifest = try ClassFixtures.manifest(rule: "frequent", classBody: "\"languages\":[\"en\"],\"top\":600,\"minZipf\":0",
                                                  scenarios: ["clean.cold", "slip.cold"], tier: 600)
        let output = try build(manifest, lexicon: ["en": words])
        var parts: [String: Set<EvalCase.Split>] = [:]
        for item in output.cases { parts[item.tokens![0].t, default: []].insert(item.split) }
        #expect(parts.values.allSatisfy { $0.count == 1 })
        let dev = parts.values.filter { $0 == [.dev] }.count
        #expect(abs(Double(dev) / Double(parts.count) - 0.5) < 0.06)
    }

    @Test func theCapCutsTheDerivedItemsByWeightAndKeepsTheSeeds() throws {
        let directory = try SuiteFixtures.directory()
        try "zzz\tmine\n".write(toFile: directory + "/seeds.txt", atomically: true, encoding: .utf8)
        let manifest = try ClassFixtures.manifest(rule: "frequent", classBody: "\"languages\":[\"en\"],\"top\":5,\"minZipf\":0,\"seeds\":\"seeds.txt\"",
                                                  tier: 2)
        let lexicon: [String: [(String, Double)]] = ["en": [("aa", 7), ("bb", 6), ("cc", 5), ("dd", 4), ("ee", 3)]]
        let output = try build(manifest, lexicon: lexicon, classes: directory)
        #expect(output.cases.compactMap { $0.tokens?.first?.t } == ["aa", "bb", "zzz"])
        #expect(output.report.classes?.cut == 3 && output.report.classes?.seeds == 1 && output.report.classes?.seedsFound == 0)
    }

    @Test func twoBuildsGiveTheSameBytesAndAWarmScenarioHasItsSentence() throws {
        let cache = try SuiteFixtures.tatoebaCache(count: 400)
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"ru\",\"en\"],\"maxLetters\":2",
                                                  scenarios: ["clean.cold", "clean.warm", "slip.warm"])
        let first = try build(manifest, lexicon: Self.lexicon, cache: cache), second = try build(manifest, lexicon: Self.lexicon, cache: cache)
        #expect(try CaseCodec.write(first.cases) == CaseCodec.write(second.cases))
        #expect(first.report == second.report)
        let warm = first.cases.filter { $0.scenario == "clean.warm" }
        #expect(!warm.isEmpty)
        for item in warm {
            #expect(item.warmup?.isEmpty == false)
            #expect(item.want.hasSuffix(item.tokens![0].t))
        }
    }

    @Test func twoSpellingsOfOneWordAreTwoItemsInOnePartAndTheOrderDoesNotDependOnTheRun() throws {
        let directory = try SuiteFixtures.directory()
        try "Zoom\nzoom\nZOOM\n".write(toFile: directory + "/seeds.txt", atomically: true, encoding: .utf8)
        let manifest = try ClassFixtures.manifest(rule: "frequent", classBody: "\"languages\":[\"en\"],\"top\":1,\"seeds\":\"seeds.txt\"", tier: 5)
        let lexicon: [String: [(String, Double)]] = ["en": [("zoom", 4)]]
        let output = try build(manifest, lexicon: lexicon, classes: directory)
        #expect(Set(output.cases.compactMap { $0.tokens?.first?.t }) == ["Zoom", "zoom", "ZOOM"])
        #expect(output.cases.count == 3 && Set(output.cases.map(\.id)).count == 3)
        #expect(Set(output.cases.map(\.split)).count == 1)
        for item in output.cases {
            let token = try #require(item.tokens?.first)
            #expect(token.tags == (token.t == "zoom" ? ["frequent", "seed"] : ["seed"]))
        }
    }

    @Test func aPinnedItemSurvivesTheCap() throws {
        let manifest = try ClassFixtures.manifest(rule: "punct", classBody: "\"languages\":[\"en\"],\"top\":3", tier: 2)
        let cache = try SuiteFixtures.directory()
        try FileManager.default.createDirectory(atPath: cache + "/tatoeba", withIntermediateDirectories: true)
        for (code, text) in [("rus", "1\trus\tТо\n"), ("eng", (0..<6).map { "\($0)\teng\tA well-known day.\n" }.joined())] {
            try text.write(toFile: cache + "/tatoeba/\(code)_sentences.tsv", atomically: true, encoding: .utf8)
            try SuiteFixtures.run("/usr/bin/bzip2", ["-f", cache + "/tatoeba/\(code)_sentences.tsv"], in: cache)
        }
        let output = try build(manifest, lexicon: ["en": [("aa", 7), ("bb", 6), ("cc", 5)]], cache: cache)
        let texts = output.cases.compactMap { $0.tokens?.first?.t }
        // Two decorated words under the cap of 2, and the hyphenated word, which weighs less than all of them.
        #expect(texts.count == 3 && texts.contains("well-known"))
        #expect(output.report.classes?.cut == 1)
    }

    @Test func aLanguageOfNoLayoutSetIsAnError() throws {
        let manifest = try ClassFixtures.manifest(rule: "short", classBody: "\"languages\":[\"uk\"],\"maxLetters\":2")
        #expect(throws: EvalError.self) { try build(manifest, lexicon: Self.lexicon) }
    }

    @Test func aUnitWithNoLetterIsTypedWhereItsAimIs() throws {
        let manifest = try ClassFixtures.manifest("protect.numbers", rule: "numbers", classBody: "\"languages\":[\"en\"]",
                                                  tier: 200)
        let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
        var words: [(String, Double)] = []
        for index in 0..<100 {
            let word: String = "hello" + String(letters[index % 26]) + String(letters[index / 26])
            words.append((word, 4.0))
        }
        let output = try build(manifest, lexicon: ["en": words])
        let digits: [EvalCase] = output.cases.filter { item in item.tokens?.allSatisfy { $0.lang == "-" } == true }
        #expect(!digits.isEmpty)
        #expect(Set(digits.map(\.start)) == ["ABC", "Russian"])
        for item in digits { #expect(item.script.allSatisfy { if case let .type(_, on) = $0 { return on == item.start } else { return true } }) }
    }
}
