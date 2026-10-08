// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct WordExceptionsTests {
    @Test func matchesCaseInsensitivelyInEitherReading() {
        var words = WordExceptions()
        _ = words.add("  Дедлайн ")
        _ = words.add("kubectl")
        #expect(words.contains("ДЕДЛАЙН"))
        #expect(words.contains("Kubectl"))
        #expect(!words.contains("kubect"))
        #expect(!words.contains(""))
    }

    @Test func validation() {
        var words = WordExceptions(mine: ["слово"])
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
        var words = WordExceptions()
        let first = words.learn("Ghbdtn", at: 100)
        let second = words.learn("ghbdtn", at: 200)
        #expect(first && !second)
        #expect(words.learned == [LearnedWord(word: "ghbdtn", learnedAt: 100)])
        #expect(words.contains("GHBDTN"))
        words.forget("Ghbdtn")
        #expect(words.isEmpty)
    }

    @Test func learningOffIgnoresUndos() {
        var words = WordExceptions(learnFromUndos: false)
        let learned = words.learn("слово", at: 1)
        #expect(!learned)
        #expect(words.isEmpty)
    }

    @Test func addingLearnedWordMovesItToMine() {
        var words = WordExceptions()
        _ = words.learn("слово", at: 1)
        let added = words.add("слово")
        #expect(added)
        #expect(words.learned.isEmpty && words.mine == ["слово"])
    }

    @Test func forgetKeepsMineAndForgetAllClearsLearned() {
        var words = WordExceptions(mine: ["a"], learned: [LearnedWord(word: "b", learnedAt: 1)])
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
        #expect(broken.words == WordExceptions())
    }

    @Test func roundTrip() throws {
        let settings = AppSettings(words: WordExceptions(mine: ["a"], learned: [LearnedWord(word: "b", learnedAt: 2.5)], learnFromUndos: false))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }
}
