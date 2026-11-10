// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyVoiceCore
import Testing

/// Chunks of `VoiceActivity.chunk` samples: speech or a pause, by seconds.
private func chunks(_ parts: [(speech: Bool, seconds: Double)]) -> [Float] {
    parts.flatMap { part in
        [Float](repeating: part.speech ? 0.9 : 0.05, count: Int((part.seconds / VoiceActivity.chunkSeconds).rounded()))
    }
}

private let chunk = VoiceActivity.chunk
private let options = SpeechSegmenter.Options(minimumPiece: 5, pause: 0.5)

struct SpeechSegmenterTests {
    @Test func theOptionsCountThePauseInWholeChunks() {
        #expect(options.minimumChunks == 20)
        #expect(options.pauseChunks == 2)
        #expect(SpeechSegmenter.Options(minimumPiece: 5, pause: 0.6).pauseChunks == 3)
    }

    @Test func aPauseBeforeTheMinimumLengthDoesNotCut() {
        var segmenter = SpeechSegmenter(options: options)
        #expect(segmenter.next(chunks([(true, 2), (false, 1), (true, 1.5)])) == nil)
        #expect(segmenter.start == 0)
    }

    @Test func aPauseAfterTheMinimumLengthCutsInItsMiddle() {
        var segmenter = SpeechSegmenter(options: options)
        // 24 chunks of speech, 4 of pause, 4 of speech.
        let probabilities = [Float](repeating: 0.9, count: 24) + [Float](repeating: 0.05, count: 4)
            + [Float](repeating: 0.9, count: 4)
        let piece = segmenter.next(probabilities)
        #expect(piece == 0..<(24 * chunk + 2 * chunk))
        #expect(segmenter.start == 26 * chunk)
        // Nothing more until another pause past the minimum from the cut.
        #expect(segmenter.next(probabilities) == nil)
    }

    @Test func aPauseShorterThanTheThresholdDoesNotCut() {
        var segmenter = SpeechSegmenter(options: options)
        let probabilities = [Float](repeating: 0.9, count: 24) + [0.05] + [Float](repeating: 0.9, count: 30)
        #expect(segmenter.next(probabilities) == nil)
    }

    @Test func speechWithoutAPauseIsNeverCut() {
        var segmenter = SpeechSegmenter(options: options)
        #expect(segmenter.next(chunks([(true, 60)])) == nil)
    }

    @Test func aPauseStillGoingOnCutsInTheMiddleOfWhatIsHeard() {
        var segmenter = SpeechSegmenter(options: options)
        let probabilities = [Float](repeating: 0.9, count: 22) + [Float](repeating: 0.05, count: 2)
        #expect(segmenter.next(probabilities) == 0..<(22 * chunk + chunk))
    }

    @Test func theNextPieceCountsItsMinimumFromTheCut() {
        var segmenter = SpeechSegmenter(options: options)
        var probabilities = [Float](repeating: 0.9, count: 22) + [Float](repeating: 0.05, count: 2)
        let first = segmenter.next(probabilities)
        #expect(first == 0..<(23 * chunk))
        // A pause 3 s after the cut: under the minimum.
        probabilities += [Float](repeating: 0.9, count: 10) + [Float](repeating: 0.05, count: 2)
        #expect(segmenter.next(probabilities) == nil)
        // Another one 6 s after it.
        probabilities += [Float](repeating: 0.9, count: 12) + [Float](repeating: 0.05, count: 3)
        let second = segmenter.next(probabilities)
        #expect(second?.lowerBound == 23 * chunk)
        #expect(second?.upperBound == (22 + 2 + 10 + 2 + 12) * chunk + 3 * chunk / 2)
    }

    @Test func theLongestPauseOfTheTailIsTheCut() {
        var segmenter = SpeechSegmenter(options: options)
        let probabilities = [Float](repeating: 0.9, count: 20) + [Float](repeating: 0.05, count: 2)
            + [Float](repeating: 0.9, count: 3) + [Float](repeating: 0.05, count: 4)
        // Both pauses are past the minimum: the longer one wins (`WindowCut`).
        #expect(segmenter.next(probabilities)?.upperBound == 25 * chunk + 2 * chunk)
    }
}

struct SegmentedTextTests {
    @Test func theNextPieceIsPromptedWithTheLastWordsOfTheText() {
        #expect(SegmentedText.prompt(dictionary: nil, previous: ["Один два три.", "Четыре пять шесть семь."], words: 3)
            == "пять шесть семь.")
        #expect(SegmentedText.prompt(dictionary: nil, previous: ["Один два."], words: 5) == "Один два.")
    }

    @Test func theDictionaryComesFirst() {
        #expect(SegmentedText.prompt(dictionary: "Perekey, Orca", previous: ["Привет мир."], words: 4)
            == "Perekey, Orca, Привет мир.")
    }

    @Test func withoutWordsOrTextTheDictionaryAlone() {
        #expect(SegmentedText.prompt(dictionary: "Perekey", previous: [], words: 8) == "Perekey")
        #expect(SegmentedText.prompt(dictionary: "Perekey", previous: ["Привет."], words: 0) == "Perekey")
        #expect(SegmentedText.prompt(dictionary: nil, previous: [], words: 8) == nil)
        #expect(SegmentedText.prompt(dictionary: "", previous: ["  "], words: 8) == nil)
    }

    @Test func thePiecesJoinWithASpace() {
        #expect(SegmentedText.outcome([.text("Один."), .noSpeech, .text("Два."), .nothingLeft]) == .text("Один. Два."))
    }

    @Test func nothingHeardInAnyPieceIsNoSpeech() {
        #expect(SegmentedText.outcome([.noSpeech, .noSpeech]) == .noSpeech)
        #expect(SegmentedText.outcome([]) == .noSpeech)
    }

    @Test func speechTheFilterTookIsNothingLeft() {
        #expect(SegmentedText.outcome([.noSpeech, .nothingLeft]) == .nothingLeft)
    }
}
