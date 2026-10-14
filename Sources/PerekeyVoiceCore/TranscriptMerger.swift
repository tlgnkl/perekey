// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Puts the tracks of a call on one scale, and gives phrases their speakers.
///
/// The tracks are transcribed apart and never mixed into one sound: the
/// microphone is «Я», the system audio «Собеседники». On speakers the others
/// reach the microphone too. Perekey cleans the text, not the sound: a word
/// of «Я» that a word of «Собеседники» matches within `echoWindow` is their
/// echo and goes.
public enum TranscriptMerger {
    /// Seconds between the starts of a word and its echo.
    public static let echoWindow = 1.0

    /// One transcript of a call: «Я» without the echo and «Собеседники», by
    /// start. Phrases without a speaker get their track's; phrases of the
    /// others a diarizer split keep theirs.
    public static func merge(me: TimedTranscript, others: TimedTranscript) -> TimedTranscript {
        let theirs = others.segments.map { segment in
            var segment = segment
            segment.speaker = segment.speaker ?? TranscriptSpeaker.others.id
            return segment
        }
        let mine = removingEcho(from: me.segments, heard: theirs).map { segment in
            var segment = segment
            segment.speaker = TranscriptSpeaker.me.id
            return segment
        }
        return TimedTranscript(segments: sorted(mine + theirs), language: me.language ?? others.language)
    }

    /// The phrases of `mine` without the words `heard` has within the window.
    /// A phrase left without words goes; one without timings of words stays.
    public static func removingEcho(from mine: [TimedSegment], heard: [TimedSegment],
                                    window: Double = echoWindow) -> [TimedSegment]
    {
        let heardWords = heard.flatMap { $0.words ?? [] }
            .compactMap { word in normalized(word.text).map { (start: word.start, key: $0) } }
            .sorted { $0.start < $1.start }
        let starts = heardWords.map(\.start)
        func isEcho(_ word: TimedWord) -> Bool {
            guard let key = normalized(word.text) else { return false }
            var i = lowerBound(starts, word.start - window)
            while i < heardWords.count, heardWords[i].start <= word.start + window {
                if heardWords[i].key == key { return true }
                i += 1
            }
            return false
        }
        return mine.compactMap { segment in
            guard let words = segment.words else { return segment }
            let kept = words.filter { !isEcho($0) }
            if kept.count == words.count { return segment }
            return rebuilt(segment, words: kept)
        }
    }

    /// Splits phrases where the diarizer hears another voice and names the
    /// voices «Спикер 1», «Спикер 2», … in order of first appearance. Each
    /// word goes to the turn it overlaps most, or to the nearest one.
    public static func attribute(_ segments: [TimedSegment], to turns: [SpeakerTurn]) -> [TimedSegment] {
        guard !turns.isEmpty else { return segments }
        let turns = turns.sorted { $0.start < $1.start }
        var numbers: [Int: Int] = [:]
        func speakerID(_ cluster: Int) -> String {
            if let number = numbers[cluster] { return TranscriptSpeaker.speaker(number).id }
            let number = numbers.count + 1
            numbers[cluster] = number
            return TranscriptSpeaker.speaker(number).id
        }
        var result: [TimedSegment] = []
        for segment in sorted(segments) {
            guard let words = segment.words, !words.isEmpty else {
                var segment = segment
                segment.speaker = speakerID(cluster(for: segment.start, segment.end, in: turns))
                result.append(segment)
                continue
            }
            var run: [TimedWord] = []
            var runCluster: Int?
            for word in words {
                let cluster = cluster(for: word.start, word.end, in: turns)
                if let runCluster, cluster != runCluster, let piece = rebuilt(segment, words: run) {
                    var piece = piece
                    piece.speaker = speakerID(runCluster)
                    result.append(piece)
                    run = []
                }
                runCluster = cluster
                run.append(word)
            }
            if let runCluster, var piece = rebuilt(segment, words: run) {
                piece.speaker = speakerID(runCluster)
                result.append(piece)
            }
        }
        return result
    }

    /// The text a word is compared by: lowercase letters and digits.
    /// Nil for a word of punctuation only.
    static func normalized(_ text: String) -> String? {
        let scalars = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return scalars.isEmpty ? nil : String(String.UnicodeScalarView(scalars))
    }

    /// The phrase made of these of its words; nil if none is left.
    static func rebuilt(_ segment: TimedSegment, words: [TimedWord]) -> TimedSegment? {
        guard let first = words.first, let last = words.last else { return nil }
        var segment = segment
        segment.start = first.start
        segment.end = last.end
        segment.words = words
        segment.text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return segment
    }

    private static func cluster(for start: Double, _ end: Double, in turns: [SpeakerTurn]) -> Int {
        var best: (overlap: Double, distance: Double, speaker: Int)?
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            let distance = overlap > 0 ? 0 : max(turn.start - end, start - turn.end)
            let candidate = (overlap: max(overlap, 0), distance: distance, speaker: turn.speaker)
            if let current = best {
                if candidate.overlap > current.overlap
                    || (candidate.overlap == current.overlap && candidate.distance < current.distance)
                {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best?.speaker ?? 0
    }

    private static func sorted(_ segments: [TimedSegment]) -> [TimedSegment] {
        segments.enumerated().sorted { a, b in
            a.element.start != b.element.start ? a.element.start < b.element.start : a.offset < b.offset
        }.map(\.element)
    }

    private static func lowerBound(_ values: [Double], _ value: Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
