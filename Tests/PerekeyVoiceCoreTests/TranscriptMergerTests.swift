// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

/// A phrase of words a second apart from `start`: " a" " b" …
private func phrase(_ text: String, at start: Double, step: Double = 0.5, speaker: String? = nil) -> TimedSegment {
    let words = text.split(separator: " ").enumerated().map { i, word in
        TimedWord(start: start + Double(i) * step, end: start + Double(i) * step + step * 0.8, text: " " + word)
    }
    return TimedSegment(start: words.first!.start, end: words.last!.end, text: text, words: words, speaker: speaker)
}

struct TranscriptMergerTests {
    @Test func tracksMergeByStartWithTheirSpeakers() {
        let me = TimedTranscript(segments: [phrase("hello there", at: 0), phrase("fine thanks", at: 10)], language: "en")
        let others = TimedTranscript(segments: [phrase("how are you", at: 4)])
        let merged = TranscriptMerger.merge(me: me, others: others)
        #expect(merged.segments.map(\.text) == ["hello there", "how are you", "fine thanks"])
        #expect(merged.segments.map(\.speaker) == ["me", "others", "me"])
        #expect(merged.language == "en")
    }

    @Test func diarizedOthersKeepTheirSpeakers() {
        let others = TimedTranscript(segments: [phrase("yes", at: 1, speaker: "speaker-2")])
        let merged = TranscriptMerger.merge(me: TimedTranscript(segments: []), others: others)
        #expect(merged.segments.map(\.speaker) == ["speaker-2"])
    }

    /// The others' words reach the microphone on speakers: they go from «Я»
    /// within a second, case and punctuation aside; the user's own words stay.
    @Test func echoWithinASecondGoes() {
        let others = [phrase("We ship on Friday.", at: 20)]
        let mine = [
            // The echo, 0.3 s late, with the user's "okay" before it.
            phrase("okay we ship on friday", at: 19.8),
            phrase("friday", at: 30),
        ]
        let cleaned = TranscriptMerger.removingEcho(from: mine, heard: others)
        #expect(cleaned.map(\.text) == ["okay", "friday"])
        #expect(cleaned[0].start == 19.8 && cleaned[0].end == 19.8 + 0.4)
    }

    @Test func echoWindowEdges() {
        let others = [phrase("word", at: 10)]
        #expect(TranscriptMerger.removingEcho(from: [phrase("word", at: 11)], heard: others).isEmpty)
        #expect(TranscriptMerger.removingEcho(from: [phrase("word", at: 9)], heard: others).isEmpty)
        #expect(TranscriptMerger.removingEcho(from: [phrase("word", at: 11.01)], heard: others).count == 1)
        #expect(TranscriptMerger.removingEcho(from: [phrase("word", at: 8.9)], heard: others).count == 1)
    }

    @Test func phraseWithoutWordTimingsStays() {
        let mine = [TimedSegment(start: 10, end: 11, text: "word")]
        #expect(TranscriptMerger.removingEcho(from: mine, heard: [phrase("word", at: 10)]) == mine)
    }

    @Test func punctuationIsNotAWord() {
        let others = [TimedSegment(start: 0, end: 1, text: "—", words: [TimedWord(start: 0, end: 1, text: " —")])]
        let mine = [TimedSegment(start: 0, end: 1, text: "—", words: [TimedWord(start: 0, end: 1, text: " —")])]
        #expect(TranscriptMerger.removingEcho(from: mine, heard: others) == mine)
    }

    /// A phrase two voices share splits where the voice changes; voices are
    /// numbered in order of appearance, not by the diarizer's clusters.
    @Test func attributionSplitsPhrasesByVoice() {
        let segments = [phrase("one two three four", at: 0, step: 1)]
        let turns = [
            SpeakerTurn(start: 0, end: 1.9, speaker: 5),
            SpeakerTurn(start: 2, end: 10, speaker: 0),
        ]
        let split = TranscriptMerger.attribute(segments, to: turns)
        #expect(split.map(\.text) == ["one two", "three four"])
        #expect(split.map(\.speaker) == ["speaker-1", "speaker-2"])
        #expect(split[1].start == 2 && split[1].end == 3.8)
    }

    @Test func wordBetweenTurnsGoesToTheNearest() {
        let segments = [phrase("a b", at: 0, step: 5)]
        let turns = [SpeakerTurn(start: 0, end: 1, speaker: 1), SpeakerTurn(start: 5.5, end: 9, speaker: 2)]
        #expect(TranscriptMerger.attribute(segments, to: turns).map(\.speaker) == ["speaker-1", "speaker-2"])
    }

    @Test func phraseWithoutWordsTakesTheTurnItOverlapsMost() {
        let segments = [TimedSegment(start: 1, end: 4, text: "x")]
        let turns = [SpeakerTurn(start: 0, end: 2, speaker: 1), SpeakerTurn(start: 2, end: 9, speaker: 2)]
        #expect(TranscriptMerger.attribute(segments, to: turns).map(\.speaker) == ["speaker-1"])
    }

    @Test func noTurnsChangeNothing() {
        let segments = [phrase("a b", at: 0)]
        #expect(TranscriptMerger.attribute(segments, to: []) == segments)
    }
}
