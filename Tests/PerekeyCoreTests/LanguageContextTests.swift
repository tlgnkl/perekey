// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// The context of a word: the languages of the words before it in the
/// sentence, and the language counts of the app it is typed in.

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

@Suite struct RecentLanguagesTests {
    @Test func keepsTheLastThreeLatestFirst() {
        var recent = RecentLanguages()
        for language in ["en", "ru", nil, "ru"] { recent.push(language) }
        #expect(recent.count == 3)
        #expect(recent.latest == "ru")
        #expect(recent[1] == nil)
        #expect(recent[2] == "ru")
        #expect(recent[3] == nil)
        #expect(recent == RecentLanguages(["ru", nil, "ru", "en"]))
    }

    @Test func aSentenceEndKeepsTheLastWord() {
        var recent = RecentLanguages(["en", "ru", "ru"])
        recent.keepLatest()
        #expect(recent == RecentLanguages(["en"]))
        recent.replaceLatest("ru")
        #expect(recent == RecentLanguages(["ru"]))
        recent.removeAll()
        #expect(recent.count == 0)
        recent.replaceLatest("en")
        #expect(recent == RecentLanguages(["en"]))
    }
}

@Suite struct ClassifierContextTests {
    let classifier = Classifier(model: ModelFixture.model)

    func decide(_ text: String, typed: LayoutMap, other: LayoutMap, recent: [String?],
                prior: LanguagePrior = LanguagePrior()) -> Classifier.Decision
    {
        classifier.classify(typed.strokes(text), typed: typed, other: other,
                            context: Classifier.Context(recent: RecentLanguages(recent), prior: prior))
    }

    @Test func agreeingWordsAddUp() {
        let one = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en"])
        let three = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en", "en", "en"])
        let options = Classifier.Options()
        let earlier = options.contextBonus * (options.contextDecay + options.contextDecay * options.contextDecay)
        #expect(three.score - one.score == earlier)
        let against = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "ru", "ru"])
        #expect(one.score - against.score == 2 * options.contextBonus + earlier)
    }

    @Test func inAMixedSentenceOnlyThePreviousWordCounts() {
        let one = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en"])
        let mixed = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: ["en", "ru", "en"])
        #expect(mixed.score == one.score)
    }

    @Test func aShortWordSwitchesAfterItsOwnLanguageOnlyInAMixedSentence() {
        // "i" typed on the Russian keys is "ш". After a Russian word it stays,
        // unless the sentence has English in it too.
        let plain = decide("ш", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "ru"])
        #expect(plain.verdict == .keep)
        let mixed = decide("ш", typed: Fixture.russian, other: Fixture.abc, recent: ["ru", "en"])
        #expect(mixed.verdict == .switch(to: en))
    }

    @Test func thePriorMovesTheScoreWithinItsLimit() {
        let none = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: [])
        let english = LanguagePrior(counts: ["en": 100_000, "ru": 10])
        let toward = decide("руддщ", typed: Fixture.russian, other: Fixture.abc, recent: [], prior: english)
        #expect(toward.score - none.score == Classifier.Options().priorLimit)
        let away = decide("ghbdtn", typed: Fixture.abc, other: Fixture.russian, recent: [], prior: english)
        let neutral = decide("ghbdtn", typed: Fixture.abc, other: Fixture.russian, recent: [])
        #expect(neutral.score - away.score == Classifier.Options().priorLimit)
    }
}

@Suite struct LanguageCountsTests {
    @Test func log2IsExactEnough() {
        #expect(abs(LanguagePrior.log2(8) - 3) < 1e-9)
        #expect(abs(LanguagePrior.log2(0.5) + 1) < 1e-9)
        #expect(abs(LanguagePrior.log2(10) - 3.321_928_094_887_362) < 1e-9)
        #expect(abs(LanguagePrior.log2(1.999) - 0.999_278_472_082_540_6) < 1e-9)
    }

    @Test func countsHalveInAHalfLife() {
        var counts = LanguageCounts()
        counts.add(["ru": 100, "en": 20], at: 1000)
        let later = counts.decayed(to: 1000 + LanguageCounts.halfLife)
        #expect(abs(later.words["ru"]! - 50) < 1e-6)
        let quarter = counts.decayed(to: 1000 + 2.5 * LanguageCounts.halfLife)
        #expect(abs(quarter.words["en"]! - 20 * 0.176_776_695_296_636_9) < 1e-6)
        // An undo takes back a word; never below zero.
        counts.add(["en": -50], at: 1000)
        #expect(counts.words["en"] == 0)
    }

    @Test func aLanguageDominatesWithEnoughWords() {
        #expect(LanguageCounts(words: ["ru": 80, "en": 10]).dominant() == nil, "too few words")
        #expect(LanguageCounts(words: ["ru": 160, "en": 40]).dominant() == "ru")
        #expect(LanguageCounts(words: ["ru": 120, "en": 80]).dominant() == nil, "no clear majority")
    }

    @Test func thePriorIsWeakOnFewWords() {
        let few = LanguagePrior(counts: ["ru": 10])
        let many = LanguagePrior(counts: ["ru": 1000, "en": 100])
        #expect(few.lean(toward: "ru", from: "en") > 0)
        #expect(few.lean(toward: "ru", from: "en") < 0.5)
        #expect(many.lean(toward: "ru", from: "en") > 2)
        #expect(many.lean(toward: "en", from: "ru") == -many.lean(toward: "ru", from: "en"))
        #expect(LanguagePrior().lean(toward: "ru", from: "en") == 0)
        #expect(many.lean(toward: "uk", from: "ru") < 0, "a language never counted is unlikely")
    }
}

@Suite struct LanguageStatsTests {
    @Test func aSiteWithEnoughWordsGivesItsOwnPrior() {
        var stats = LanguageStats()
        stats.record(LanguageTally(app: "com.apple.Safari", site: "mail.ru", words: ["ru": 300]), at: 0)
        stats.record(LanguageTally(app: "com.apple.Safari", site: "github.com", words: ["en": 20]), at: 0)
        let site = stats.prior(app: "com.apple.Safari", site: "mail.ru", at: 0)
        #expect(site.lean(toward: "ru", from: "en") > 1)
        // Too few words on the site: the browser's counts speak.
        let fallback = stats.prior(app: "com.apple.Safari", site: "github.com", at: 0)
        #expect(fallback.lean(toward: "ru", from: "en") > 1)
        #expect(stats.prior(app: "org.other", site: nil, at: 0).isEmpty)
        #expect(stats.dominantLanguage(app: "com.apple.Safari", at: 0) == "ru")
    }

    @Test func resetForgetsTheAppAndOnRequestItsSites() {
        var stats = LanguageStats()
        stats.record(LanguageTally(app: "com.apple.Safari", site: "mail.ru", words: ["ru": 300]), at: 0)
        stats.reset(app: "com.apple.Safari")
        #expect(stats.apps.isEmpty)
        #expect(stats.sites.count == 1)
        stats.reset(app: "com.apple.Safari", sites: true)
        #expect(stats.sites.isEmpty)
    }

    @Test func pruneDropsFadedCountsAndOldSites() {
        var stats = LanguageStats()
        stats.record(LanguageTally(app: "org.old", site: nil, words: ["en": 2]), at: 0)
        for index in 0...LanguageStats.maxSites {
            stats.record(LanguageTally(app: nil, site: "site\(index).example", words: ["en": 100]),
                         at: Double(index))
        }
        stats.prune(at: Double(LanguageStats.maxSites) + 2 * LanguageCounts.halfLife)
        #expect(stats.apps.isEmpty, "two words fade below one in two half-lives")
        #expect(stats.sites.count == LanguageStats.maxSites)
        #expect(stats.sites["site0.example"] == nil, "the oldest site goes first")
    }

    @Test func roundTripsAndReadsWithoutAVersion() throws {
        var stats = LanguageStats()
        stats.record(LanguageTally(app: "com.apple.TextEdit", site: nil, words: ["ru": 3, "en": 1]), at: 5)
        let data = try JSONEncoder().encode(stats)
        #expect(try JSONDecoder().decode(LanguageStats.self, from: data) == stats)
        #expect(try JSONDecoder().decode(LanguageStats.self, from: Data("{}".utf8)) == LanguageStats())
    }
}

@Suite struct LanguageTallyTests {
    static let textEdit = LanguageContext(app: "com.apple.TextEdit")

    func tallies(_ desk: Desk) -> [LanguageTally] {
        desk.log.compactMap { if case let .languagesCounted(tally) = $0 { tally } else { nil } }
    }

    @Test func aTallyGoesOutEverySixtyFourWords() throws {
        var desk = Desk()
        desk.send(.languageContextChanged(Self.textEdit))
        for _ in 0..<WordJudge.tallySize { desk.type("hello ") }
        let tally = try #require(tallies(desk).first)
        #expect(tally.app == "com.apple.TextEdit")
        #expect(tally.words == ["en": WordJudge.tallySize])
        #expect(tallies(desk).count == 1)
    }

    @Test func aNewContextTakesTheCountsOfTheOldOne() throws {
        var desk = Desk()
        desk.send(.languageContextChanged(Self.textEdit))
        desk.type("hello world [jhjij ")
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Safari", site: "github.com")))
        let tally = try #require(tallies(desk).first)
        #expect(tally.app == "com.apple.TextEdit")
        #expect(tally.site == nil)
        #expect(tally.words == ["en": 2, "ru": 1])
        desk.send(.languageContextChanged(Self.textEdit))
        #expect(tallies(desk).count == 1, "nothing counted on the site")
    }

    @Test func anUndoMovesTheWordToItsLayout() throws {
        var desk = Desk()
        desk.send(.languageContextChanged(Self.textEdit))
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        #expect(desk.text == "[jhjij ")
        desk.send(.languageContextChanged(LanguageContext()))
        let tally = try #require(tallies(desk).first)
        #expect(tally.words["en"] == 1)
        #expect(tally.words["ru", default: 0] == 0)
    }

    @Test func aWordJudgedTwiceCountsOnce() throws {
        var desk = Desk()
        desk.send(.languageContextChanged(Self.textEdit))
        desk.type("hello. world, ")
        desk.send(.languageContextChanged(LanguageContext()))
        #expect(try #require(tallies(desk).first).words == ["en": 2])
    }

    @Test func theStoredCountsHoldNoText() throws {
        var desk = Desk()
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.TextEdit", site: "mail.example")))
        let words = ["hello", "world", "[jhjij", "ghbdtn", "vbh", "keyboard"]
        desk.type(words.joined(separator: " ") + " ")
        desk.send(.languageContextChanged(LanguageContext()))
        var stats = LanguageStats()
        for tally in tallies(desk) { stats.record(tally, at: 1000) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try #require(String(data: encoder.encode(stats), encoding: .utf8))
        for word in words + ["хорошо", "привет", "мир"] { #expect(!json.contains(word)) }
        // Only bundle IDs, language codes, numbers and the format's own keys: no host.
        #expect(!json.contains("mail.example"))
        let strings = json.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        let allowed: Set<String> = ["apps", "version", "words", "updated", "en", "ru", "com.apple.TextEdit"]
        #expect(Set(strings).isSubset(of: allowed), "\(json)")
    }
}

@Suite struct WordJudgeContextTests {
    let layouts = LayoutState([Fixture.abc, Fixture.russian], current: en)

    func judge(_ judge: inout WordJudge, _ text: String, endedBy keyCode: UInt16 = KeyCode.space) {
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes(text) { buffer.type(stroke, in: en) }
        judge.typed(startsWord: true)
        _ = judge.judge(endedBy: KeyEvent(.down, keyCode: keyCode), held: 0, buffer: buffer, layouts: layouts,
                        settings: Settings(), focus: Desk.textEdit, secureInput: false)
    }

    @Test func aSentenceEndLeavesItsLastWord() {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        judge(&wordJudge, "hello")
        judge(&wordJudge, "world")
        #expect(wordJudge.recent.count == 2)
        judge(&wordJudge, "today", endedBy: KeyCode.return)
        #expect(wordJudge.recent == RecentLanguages(["en"]))
        wordJudge.forgetContext(newField: false)
        #expect(wordJudge.recent.count == 0)
    }

    @Test func theExplanationHasTheContextTheDecisionHad() throws {
        var wordJudge = WordJudge(classifier: Desk.classifier)
        let russian = LayoutState([Fixture.abc, Fixture.russian], current: ru)
        for word in ["привет", "мир"] {
            var buffer = WordBuffer()
            for stroke in Fixture.russian.strokes(word) { buffer.type(stroke, in: ru) }
            wordJudge.typed(startsWord: true)
            _ = wordJudge.judge(endedBy: KeyEvent(.down, keyCode: KeyCode.space), held: 0, buffer: buffer,
                                layouts: russian, settings: Settings(), focus: Desk.textEdit, secureInput: false)
        }
        #expect(wordJudge.recent == RecentLanguages(["ru", "ru"]))
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes("ghbdtn") { buffer.type(stroke, in: en) }
        wordJudge.typed(startsWord: true)
        guard case let .retype(retype) = wordJudge.judge(
            endedBy: KeyEvent(.down, keyCode: KeyCode.space), held: 0, buffer: buffer, layouts: layouts,
            settings: Settings(), focus: Desk.textEdit, secureInput: false
        ) else {
            Issue.record("expected a switch")
            return
        }
        let expected = Desk.classifier.classify(Fixture.abc.strokes("ghbdtn"), typed: Fixture.abc,
                                                other: Fixture.russian,
                                                context: Classifier.Context(recent: RecentLanguages(["ru", "ru"])))
        #expect(try #require(retype.decision).score == expected.score)
    }
}
