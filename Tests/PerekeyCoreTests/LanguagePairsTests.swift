// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct LanguagePairsTests {
    private func pair(_ first: String, _ second: String) -> LanguagePairs.Pair {
        LanguagePairs.Pair(first: first, second: second)
    }

    @Test func twoLanguagesAreOneAutomaticPair() {
        let pairs = LanguagePairs(languages: ["en", "ru"])
        #expect(pairs.automatic == [pair("en", "ru")])
        #expect(pairs.manualOnly.isEmpty)
        #expect(!pairs.hasChoice)
    }

    @Test func cyrillicPairIsManualOnly() {
        let pairs = LanguagePairs(languages: ["en", "ru", "uk"])
        #expect(pairs.automatic == [pair("en", "ru"), pair("en", "uk")])
        #expect(pairs.manualOnly == [pair("ru", "uk")])
        #expect(pairs.hasChoice)
    }

    @Test func layoutsOfOneLanguageCountOnce() {
        let pairs = LanguagePairs(languages: ["en", "en", "ru"])
        #expect(pairs.languages == ["en", "ru"])
        #expect(pairs.automatic == [pair("en", "ru")])
    }

    @Test func twoLatinLanguagesAreManualOnly() {
        let pairs = LanguagePairs(languages: ["en", "de"])
        #expect(pairs.automatic.isEmpty)
        #expect(pairs.manualOnly == [pair("en", "de")])
    }

    @Test func aLanguageWithoutAScriptHasNoPair() {
        let pairs = LanguagePairs(languages: ["en", "ja", "ru"])
        #expect(pairs.languages == ["en", "ja", "ru"])
        #expect(pairs.automatic == [pair("en", "ru")])
        #expect(pairs.manualOnly.isEmpty)
    }

    @Test func theRuleMatchesTheClassifier() {
        let pairs = LanguagePairs(languages: ["en", "ru", "uk", "de"])
        for found in pairs.automatic { #expect(Classifier.switchesAutomatically(from: found.first, to: found.second)) }
        for found in pairs.manualOnly { #expect(!Classifier.switchesAutomatically(from: found.first, to: found.second)) }
    }
}
