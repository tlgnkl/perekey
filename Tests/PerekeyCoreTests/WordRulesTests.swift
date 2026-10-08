// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct WordRulesTests {
    @Test func matchesCaseInsensitivelyInEitherReading() {
        var words = WordRules()
        _ = words.add("  Дедлайн ")
        _ = words.add("kubectl")
        #expect(words.contains("ДЕДЛАЙН"))
        #expect(words.contains("Kubectl"))
        #expect(!words.contains("kubect"))
        #expect(!words.contains(""))
    }

    @Test func validation() {
        var words = WordRules(mine: ["слово"])
        #expect(words.validate("   ") == .empty)
        #expect(words.validate("two words") == .invalid)
        #expect(words.validate("123") == .invalid)
        #expect(words.validate("rock'n-roll") == .ok)
        #expect(words.validate("СЛОВО") == .duplicate)
        #expect(words.validate("привет", isFrequent: { $0 == "привет" }) == .frequent)
        let first = words.add("привет")
        let second = words.add("привет")
        #expect(first && !second)
    }

    @Test func learnAndForget() {
        var words = WordRules()
        let first = words.learn("Ghbdtn", at: 100)
        let second = words.learn("ghbdtn", at: 200)
        #expect(first && !second)
        #expect(words.learned == [LearnedWord(word: "ghbdtn", learnedAt: 100, undoCount: 2, lastUndoneAt: 200)])
        #expect(words.contains("GHBDTN"))
        words.forget("Ghbdtn")
        #expect(words.isEmpty)
    }

    @Test func learningOffIgnoresUndos() {
        var words = WordRules(learnFromUndos: false)
        let learned = words.learn("слово", at: 1)
        #expect(!learned)
        #expect(words.isEmpty)
    }

    @Test func addingLearnedWordMovesItToMine() {
        var words = WordRules()
        _ = words.learn("слово", at: 1)
        let added = words.add("слово")
        #expect(added)
        #expect(words.learned.isEmpty && words.mine == ["слово"])
    }

    @Test func forgetKeepsMineAndForgetAllClearsLearned() {
        var words = WordRules(mine: ["a"], learned: [LearnedWord(word: "b", learnedAt: 1)])
        words.forget("a")
        #expect(words.mine == ["a"])
        words.forgetAllLearned()
        #expect(words.learned.isEmpty)
    }

    @Test func tolerantDecoding() throws {
        let json = #"{"words":{"mine":["Слово","слово",""],"learned":[{"word":"x","learnedAt":5},{"bad":1},{"word":"X","learnedAt":6}]}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.words.mine == ["слово"])
        #expect(settings.words.learned == [LearnedWord(word: "x", learnedAt: 5)])
        #expect(settings.words.learnFromUndos)
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"words":"nope"}"#.utf8))
        #expect(broken.words == WordRules())
    }

    @Test func roundTrip() throws {
        let settings = AppSettings(words: WordRules(
            mine: ["a"], learned: [LearnedWord(word: "b", learnedAt: 2.5, undoCount: 3, lastUndoneAt: 9)],
            always: ["аня"], learnFromUndos: false
        ))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    // MARK: - Always fix

    @Test func alwaysFixValidation() {
        let words = WordRules(mine: ["kubectl"], learned: [LearnedWord(word: "fyz", learnedAt: 1)], always: ["аня"])
        #expect(words.validate("Аня", for: .always) == .duplicate)
        #expect(words.validate("kubectl", for: .always) == .neverTouch)
        #expect(words.validate("fyz", for: .always) == .ok, "a learned word moves")
        #expect(words.validate("two words", for: .always) == .invalid)
        #expect(words.validate("и", for: .always, isFrequent: { _ in true }) == .ok, "no frequency warning")
        #expect(words.validate("аня") == .ok, "«Мои» takes an always-fix word: never-touch wins")
        #expect(words.validate("fyz") == .duplicate)
        #expect(words.section(of: " АНЯ ") == .always)
        #expect(!words.contains("аня"), "always-fix is not never-touch")
    }

    @Test func alwaysFixMovesLearnedWordsAndRefusesMine() {
        var words = WordRules(mine: ["kubectl"], learned: [LearnedWord(word: "fyz", learnedAt: 1),
                                                           LearnedWord(word: "гошан", learnedAt: 2)])
        let moved = words.alwaysFix(" Аня ", typed: "Fyz")
        #expect(moved)
        #expect(words.always == ["аня"])
        #expect(words.learned.map(\.word) == ["гошан"], "the user's retype contradicts the old undo")
        let fromLearned = words.alwaysFix("гошан")
        #expect(fromLearned)
        #expect(words.learned.isEmpty)
        let mine = words.alwaysFix("kubectl")
        #expect(!mine, "never-touch wins")
        let mineTyped = words.alwaysFix("лщиусед", typed: "kubectl")
        #expect(!mineTyped, "never-touch wins in the other reading too")
        let again = words.alwaysFix("аня")
        #expect(!again)
        #expect(words.always == ["аня", "гошан"])
        words.stopFixing("АНЯ")
        #expect(words.always == ["гошан"])
    }

    @Test func addingAlwaysFixWordToMineMovesIt() {
        var words = WordRules(always: ["аня"])
        let added = words.add("Аня")
        #expect(added)
        #expect(words.mine == ["аня"] && words.always.isEmpty)
    }

    @Test func learningSkipsAlwaysFixWords() {
        var words = WordRules(always: ["аня"])
        let learned = words.learn("аня", at: 1)
        #expect(!learned)
        #expect(words.learned.isEmpty)
    }

    @Test func repeatedUndoCountsInsteadOfDuplicating() {
        var words = WordRules()
        words.learn("ghbdtn", at: 10)
        words.learn("GHBDTN", at: 20)
        words.learn("ghbdtn", at: 30)
        #expect(words.learned == [LearnedWord(word: "ghbdtn", learnedAt: 10, undoCount: 3, lastUndoneAt: 30)])
        words.learnFromUndos = false
        words.learn("ghbdtn", at: 40)
        #expect(words.learned.first?.undoCount == 3, "learning off counts nothing")
    }

    @Test func snapshotDropsAlwaysFixWordsOnNeverTouchLists() {
        let words = WordRules(mine: ["аня"], learned: [LearnedWord(word: "гошан", learnedAt: 1)],
                              always: ["аня", "гошан", "вася"])
        let snapshot = AppSettings(words: words).snapshot
        #expect(snapshot.exceptions == ["аня", "гошан"])
        #expect(snapshot.alwaysFix == ["вася"])
    }

    @Test func decodingKeepsAWordOnOneListOnly() throws {
        let json = #"{"words":{"mine":["аня"],"learned":[{"word":"вася","learnedAt":1}],"always":["Аня","вася","гошан",""]}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.words.mine == ["аня"])
        #expect(settings.words.learned.map(\.word) == ["вася"])
        #expect(settings.words.always == ["гошан"])
    }

    // MARK: - Migration

    /// A settings file as Perekey wrote it before "Всегда исправлять" and the undo count.
    @Test func settingsFileFromBeforeTheRulesLoads() throws {
        let url = try #require(Bundle.module.url(forResource: "settings-v1", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
        #expect(settings.words.mine == ["kubectl", "перекей"])
        #expect(settings.words.learned == [
            LearnedWord(word: "ghbdtn", learnedAt: 1_790_000_000, undoCount: 1, lastUndoneAt: 1_790_000_000),
            LearnedWord(word: "дедлайн", learnedAt: 1_790_086_400.5, undoCount: 1, lastUndoneAt: 1_790_086_400.5),
        ])
        #expect(settings.words.always.isEmpty)
        #expect(settings.words.learnFromUndos)
        #expect(settings.apps["com.apple.Terminal"]?.mode == .manualOnly)
        #expect(!settings.typoCorrection)
        // Saved again, it keeps everything and gains the new fields.
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
        #expect(settings.snapshot.alwaysFix.isEmpty)
    }

    @Test func learnedWordWithBadCountKeepsTheWord() throws {
        let json = #"{"word":"x","learnedAt":5,"undoCount":"many","lastUndoneAt":null}"#
        let word = try JSONDecoder().decode(LearnedWord.self, from: Data(json.utf8))
        #expect(word == LearnedWord(word: "x", learnedAt: 5, undoCount: 1, lastUndoneAt: 5))
    }
}
