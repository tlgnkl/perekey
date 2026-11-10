// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

struct SpeechScoreTests {
    @Test func caseAndPunctuationDoNotCount() {
        let reference = "Основной религией в Молдавии является православное христианство."
        let heard = "основной религией, в молдавии является православное христианство"
        #expect(SpeechScore.wordErrors(reference: reference, hypothesis: heard) == 0)
        #expect(SpeechScore.characterErrors(reference: reference, hypothesis: heard) == 0)
    }

    @Test func apostrophesJoinTheWord() {
        #expect(SpeechScore.words("Don’t stop, don't!") == ["dont", "stop", "dont"])
    }

    @Test func hyphenAndSlashSplitWords() {
        #expect(SpeechScore.words("кто-нибудь и/или") == ["кто", "нибудь", "и", "или"])
    }

    @Test func aSubstitutionAnInsertionAndADeletionEachCostOne() {
        #expect(SpeechScore.wordErrors(reference: "a b c", hypothesis: "a x c") == 1)
        #expect(SpeechScore.wordErrors(reference: "a b c", hypothesis: "a b c d") == 1)
        #expect(SpeechScore.wordErrors(reference: "a b c", hypothesis: "a c") == 1)
        #expect(SpeechScore.wordErrors(reference: "a b c", hypothesis: "") == 3)
    }

    @Test func charactersCountSpacesBetweenWords() {
        // "ab cd" against "abcd": one space is missing.
        #expect(SpeechScore.characterErrors(reference: "ab cd", hypothesis: "abcd") == 1)
        #expect(SpeechScore.characterErrors(reference: "кот", hypothesis: "кит") == 1)
    }

    @Test func theRatesAddUpOverRecordings() {
        var tally = SpeechScore.Tally()
        tally.add(reference: "один два три четыре", hypothesis: "один два три четыре")
        tally.add(reference: "a b", hypothesis: "a x")
        #expect(tally.referenceWords == 6)
        #expect(tally.wordErrors == 1)
        #expect(abs(tally.wordErrorRate - 1.0 / 6.0) < 1e-12)
        #expect(tally.characterErrors == 1)
        #expect(tally.recordings == 2)
    }

    @Test func anEmptyTallyHasNoRate() {
        let tally = SpeechScore.Tally()
        #expect(tally.wordErrorRate == 0)
        #expect(tally.characterErrorRate == 0)
    }

    @Test func theLeadingWordsOfAReferenceFollowTheShareHeard() {
        let reference = "один два три четыре пять шесть семь восемь девять десять"
        #expect(SpeechScore.leadingWords(of: reference, share: 0.3) == "один два три")
        #expect(SpeechScore.leadingWords(of: reference, share: 0.0) == "один")
        #expect(SpeechScore.leadingWords(of: reference, share: 1.5) == reference)
    }
}
