// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// The lexicon, the labels `disputed` and `silent`, and the features that need them.
@Suite struct LexiconTests {
    @Test func aWordIsKeptWithoutItsCaseOrItsYo() {
        let lexicon = Lexicon(words: ["ru": [("Ёлка", 3.2), ("привет", 5.5)], "en": [("hello", 5)]])
        #expect(abs(lexicon.zipf(of: "елка", language: "ru")! - 3.2) < 1e-6)
        #expect(lexicon.zipf(of: "ПРИВЕТ", language: "ru") == 5.5, "5.5 is exact in a Float")
        #expect(lexicon.zipf(of: "привет", language: "en") == nil)
        #expect(lexicon.contains("hello", language: "en"))
        #expect(!lexicon.contains("hello", language: "de"))
        #expect(lexicon.has(language: "ru") && !lexicon.has(language: "de"))
    }

    @Test func theCoreLosesTheMarksAtItsEnds() {
        #expect(Lexicon.core("«Привет,»") == "привет")
        #expect(Lexicon.core("(во-первых)") == "во-первых")
        #expect(Lexicon.core("п'ять.") == "п'ять")
        #expect(Lexicon.core("...") == "")
        #expect(Lexicon.core("mp3") == "mp3")
    }

    @Test func theScriptIsOneOrNone() {
        #expect(Lexicon.script(of: "привет") == .cyrillic)
        #expect(Lexicon.script(of: "hello") == .latin)
        #expect(Lexicon.script(of: "hello-мир") == nil)
        #expect(Lexicon.script(of: "123") == nil)
    }

    @Test func aFileOfTheDirectoryIsReadAndNeedsNoCache() throws {
        let directory = NSTemporaryDirectory() + "lexicon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try "hello\t5.40\nworld\t0.00\n".write(toFile: directory + "/lexicon-en.tsv", atomically: true, encoding: .utf8)
        let lexicon = try Lexicon.load(languages: ["en"], directory: directory, cache: nil)
        #expect(abs(lexicon.zipf(of: "Hello", language: "en")! - 5.4) < 1e-6)
        #expect(lexicon.zipf(of: "world", language: "en") == 0)
        #expect(throws: EvalError.self) { try Lexicon.load(languages: ["ru"], directory: directory, cache: nil) }
    }

    @Test func theSeenWordsAreTheListsOfData() throws {
        let directory = NSTemporaryDirectory() + "data-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: directory + "/ru", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: directory + "/mixed", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: directory) }
        try "# header\nокей\nрефакторинг # note\nслово\t12\n".write(toFile: directory + "/ru/add.txt", atomically: true, encoding: .utf8)
        try "iPhone\n".write(toFile: directory + "/mixed/keep.txt", atomically: true, encoding: .utf8)
        try "ignored\n".write(toFile: directory + "/model.sha256", atomically: true, encoding: .utf8)
        let seen = try SeenWords(directory: directory)
        #expect(seen.contains("Окей") && seen.contains("рефакторинг") && seen.contains("слово") && seen.contains("iphone"))
        #expect(!seen.contains("header") && !seen.contains("note") && !seen.contains("ignored"))
    }

    @Test func theSeenHashChangesWithTheLists() {
        #expect(SeenWords(words: ["а", "б"]).hash == SeenWords(words: ["б", "а"]).hash)
        #expect(SeenWords(words: ["а"]).hash != SeenWords(words: ["а", "б"]).hash)
    }
}

@Suite struct NoiseDecisionTests {
    @Test func linesAreReadAndCommentsSkipped() throws {
        var noise = NoiseDecisions()
        try noise.add("# comment\n\nsuite/clean.cold/aaaaaaaaaaaa\t2\tsource-typo\tпривет\nsuite/clean.cold/aaaaaaaaaaaa\t3\tharm\n")
        var item = Cases.make([.type("привет ", on: "Russian")], want: "привет")
        item.id = "suite/clean.cold/aaaaaaaaaaaa"
        #expect(noise.decisions(for: item) == [2: .sourceTypo(form: "привет"), 3: .harm])
    }

    @Test func theTestPartHasNoDecisions() throws {
        var noise = NoiseDecisions()
        try noise.add("x\t0\tharm\n")
        var item = Cases.make([.type("привет ", on: "Russian")], want: "привет")
        item.id = "x"
        #expect(noise.decisions(for: item) == [0: .harm])
        item.split = .test
        #expect(noise.decisions(for: item).isEmpty)
    }

    @Test func badLinesAreErrors() {
        for line in ["x\tone\tharm", "x\t0\tmaybe", "x\t0\tsource-typo", "x\t0", "x\t-1\tharm"] {
            var noise = NoiseDecisions()
            #expect(throws: EvalError.self, "\(line)") { try noise.add(line + "\n") }
        }
    }
}

@Suite struct DisputedAndSilentTests {
    static let lexicon = Lexicon(words: [
        "ru": [("привет", 5.5), ("коечто", 3.4), ("мир", 5), ("редкость", 2.5), ("мы", 6)],
        "en": [("hello", 5.5), ("vs", 4), ("ghbdtn", 1)],
    ])

    func scorer(decisions: NoiseDecisions = NoiseDecisions(), seen: SeenWords? = nil) -> Scorer {
        Scorer(library: Repo.library, knowledge: Knowledge(lexicon: Self.lexicon, seen: seen, noise: decisions))
    }

    func item(_ want: String, lang: String = "ru", suite: String = "prose.test", split: EvalCase.Split = .dev,
              tags: [String]? = nil) -> EvalCase
    {
        var item = Cases.make([.type(want + " ", on: lang == "ru" ? "Russian" : "ABC")], want: want,
                              tokens: [TokenSpec(t: want, lang: lang)], suite: suite)
        item.split = split
        item.tags = tags
        return try! item.identified()
    }

    func outcome(_ item: EvalCase, null: String, out: String, scorer: Scorer? = nil) -> TokenScore {
        (scorer ?? self.scorer()).score(item, null: result(null), out: result(out)).tokens[0]
    }

    @Test func aHarmThatMendsTheSourcesTypoIsDisputed() {
        // «превет» is not a word; the system gives «привет», a word, one edit away.
        let token = outcome(item("превет"), null: "превет", out: "привет")
        #expect(token.outcome == .disputed)
        #expect(Outcome.disputed.letter == "D")
    }

    @Test func aHarmIsKeptWhenTheIntendedWordIsInTheLexicon() {
        #expect(outcome(item("мир"), null: "мир", out: "мы").outcome == .harm)
    }

    @Test func aHarmIsKeptWhenTheSystemsWordIsRareOrFar() {
        // Zipf 2.5 < 3.
        #expect(outcome(item("рекость"), null: "рекость", out: "редкость").outcome == .harm)
        // Two edits.
        #expect(outcome(item("пруветик"), null: "пруветик", out: "привет").outcome == .harm)
    }

    @Test func aHyphenOrYoAloneIsOneEdit() {
        // «кое-что» is not in the lexicon, «коечто» is: they differ by the hyphen only.
        #expect(outcome(item("кое-что"), null: "кое-что", out: "коечто").outcome == .disputed)
    }

    @Test func aSwapOfNeighboursIsOneEdit() {
        #expect(outcome(item("првиет"), null: "првиет", out: "привет").outcome == .disputed)
    }

    @Test func theKnownSuitesHaveNoDisputedOutcome() {
        for suite in ["class.short", "protect.url", "typos.none", "flow.basics", "incidents", "yo", "hyphen",
                      "doublecap", "capslock", "abbrev"]
        {
            #expect(outcome(item("превет", suite: suite), null: "превет", out: "привет").outcome == .harm, "\(suite)")
        }
        #expect(outcome(item("превет", suite: "tech.ruso"), null: "превет", out: "привет").outcome == .disputed)
    }

    @Test func aHarmThatChangesTheLayoutIsNeverDisputed() {
        #expect(outcome(item("превет"), null: "превет", out: "ghtdtn").outcome == .harm)
    }

    @Test func aDecisionHarmReturnsTheHarm() throws {
        let probe = item("превет")
        var noise = NoiseDecisions()
        try noise.add("\(probe.id)\t0\tharm\n")
        #expect(outcome(probe, null: "превет", out: "привет", scorer: scorer(decisions: noise)).outcome == .harm)
    }

    @Test func aDecisionSourceTypoAcceptsTheForm() throws {
        let probe = item("превет")
        var noise = NoiseDecisions()
        try noise.add("\(probe.id)\t0\tsource-typo\tпривет\n")
        #expect(outcome(probe, null: "превет", out: "привет", scorer: scorer(decisions: noise)).outcome == .ok)
    }

    @Test func theTestPartKeepsTheRuleAndIgnoresTheFile() throws {
        var probe = item("превет", split: .test)
        probe = try probe.identified()
        var noise = NoiseDecisions()
        try noise.add("\(probe.id)\t0\tharm\n")
        #expect(outcome(probe, null: "превет", out: "привет", scorer: scorer(decisions: noise)).outcome == .disputed)
    }

    @Test func aDisputedTokenIsNotHarmInTheMetrics() {
        let probe = item("превет")
        let score = scorer().score(probe, null: result("превет"), out: result("привет"))
        var metrics = Metrics(score)
        metrics.computeRates()
        #expect(metrics.harm == 0 && metrics.disputed == 1 && metrics.wrong == 0)
        #expect(metrics.rates.disputed == 1000 && metrics.rates.harm == 0)
        #expect(!score.exact, "the text is not the intended one")
        #expect(RunFiles.casesTSV([score]).contains("\tD\t"))
    }

    @Test func aHarmOrBotchThatIsAWordIsSilent() {
        // «привет» typed, «ghbdtn» out: harm of form layout; the English lexicon holds «ghbdtn» here.
        let silent = outcome(item("привет"), null: "привет", out: "ghbdtn")
        #expect(silent.outcome == .harm && silent.silent)
        let loud = outcome(item("привет"), null: "привет", out: "ghbdtnn")
        #expect(loud.outcome == .harm && !loud.silent)
        let fine = outcome(item("привет"), null: "привет", out: "привет")
        #expect(!fine.silent)
    }

    @Test func silentNeedsTheScriptOfTheLanguage() {
        // «мир» is a Russian word; out in Latin letters is not looked up in the Russian lexicon.
        let token = outcome(item("привет"), null: "привет", out: "мир")
        #expect(token.silent)
        let latin = Knowledge(lexicon: Lexicon(words: ["ru": [("hello", 5)]]))
        #expect(!latin.isSilent(out: "hello", languages: ["ru"]))
    }

    @Test func withoutKnowledgeThereIsNothingNew() {
        let plain = Scorer(library: Repo.library).score(item("превет"), null: result("превет"), out: result("привет"))
        #expect(plain.tokens[0].outcome == .harm)
        #expect(plain.tokens[0].features?.zipf == nil && plain.tokens[0].features?.seen == nil)
        #expect(plain.tokens[0].features?.known == nil && plain.tokens[0].features?.collision == nil)
    }

    @Test func theFeaturesNeedingTheLexiconAreSet() {
        let seen = SeenWords(words: ["привет"])
        let hit = scorer(seen: seen).score(item("привет"), null: result("привет"), out: result("привет"),
                                           model: ModelFixture.model).tokens[0].features
        #expect(hit?.zipf == "5+" && hit?.seen == "yes" && hit?.known == "yes" && hit?.collision == "no")
        let miss = scorer(seen: seen).score(item("превет"), null: result("превет"), out: result("превет"),
                                            model: ModelFixture.model).tokens[0].features
        #expect(miss?.zipf == "none" && miss?.seen == "no" && miss?.known == "no")
        let withoutModel = scorer().score(item("привет"), null: result("привет"), out: result("привет")).tokens[0].features
        #expect(withoutModel?.known == nil && withoutModel?.seen == nil, "no lists, no model: the features stay out")
        #expect(withoutModel?.zipf == "5+")
    }

    @Test func theZipfRanges() {
        let knowledge = Knowledge(lexicon: Lexicon(words: ["en": [("a", 1.5), ("b", 2.5), ("c", 3.5), ("d", 4.5), ("e", 6)]]))
        #expect(["a", "b", "c", "d", "e", "f"].map { knowledge.zipfBucket($0, language: "en") }
            == ["<2", "2-3", "3-4", "4-5", "5+", "none"])
        #expect(knowledge.zipfBucket("a", language: "-") == "none")
    }

    @Test func aCollisionIsAWordInTheOtherLayout() {
        // «vs» on ABC is «мы» on Russian: a word of Zipf 6.
        let token = scorer().score(item("vs", lang: "en"), null: result("vs"), out: result("vs")).tokens[0].features
        #expect(token?.collision == "yes")
        let none = scorer().score(item("hello", lang: "en"), null: result("hello"), out: result("hello")).tokens[0].features
        #expect(none?.collision == "no")
    }

    @Test func theTagsOfTheCaseJoinTheTagsOfTheToken() {
        var probe = item("привет", tags: ["mixed", "natural"])
        probe.tokens = [TokenSpec(t: "привет", lang: "ru", tags: ["brand", "mixed"])]
        let features = Scorer(library: Repo.library).score(probe, null: result("привет"), out: result("привет"))
            .tokens[0].features
        #expect(features?.tags == ["mixed", "natural", "brand"])
    }

    @Test func theEditDistance() {
        func d(_ a: String, _ b: String) -> Int { Knowledge.distance(Array(a), Array(b)) }
        #expect(d("", "") == 0 && d("а", "") == 1 && d("привет", "превет") == 1)
        #expect(d("првиет", "привет") == 1, "a swap of neighbours is one")
        #expect(d("привет", "приветик") == 2)
    }
}
