// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyVoiceCore
import Testing

@Suite("SubtitleWriter")
struct SubtitleWriterTests {
    static let labels = SpeakerLabels(me: "Я", others: "Собеседники", speaker: { "Спикер \($0)" })

    static func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(start: start, end: end, text: text)
    }

    static func document(_ segments: [TimedSegment]) -> TranscriptDocument {
        TranscriptDocument(model: "parakeet-tdt-v3", engine: "parakeet", language: "ru",
                           createdAt: Date(timeIntervalSince1970: 1_700_000_000), segments: segments)
    }

    static let call = document([
        TimedSegment(start: 0.5, end: 2.25, text: "Привет, как дела?", speaker: "me"),
        TimedSegment(start: 3, end: 5, text: "Всё хорошо, спасибо.", speaker: "others"),
    ])

    private func srtTimes(_ text: String) -> [String] {
        text.split(separator: "\n").filter { $0.contains("-->") }.map(String.init)
    }

    // MARK: Times

    @Test("hour boundaries round as integers")
    func hours() {
        #expect(SubtitleWriter.timecode(0, separator: ",") == "00:00:00,000")
        #expect(SubtitleWriter.timecode(59.9996, separator: ",") == "00:01:00,000")
        #expect(SubtitleWriter.timecode(3599.9996, separator: ",") == "01:00:00,000")
        #expect(SubtitleWriter.timecode(3600, separator: ".") == "01:00:00.000")
        #expect(SubtitleWriter.timecode(36_000 + 61.5, separator: ".") == "10:01:01.500")
        #expect(SubtitleWriter.timecode(100 * 3600, separator: ",") == "100:00:00,000")
        #expect(SubtitleWriter.timecode(-3, separator: ",") == "00:00:00,000")
        #expect(SubtitleWriter.timecode(.nan, separator: ",") == "00:00:00,000")
    }

    // MARK: SRT

    @Test("SRT numbers from 1, uses a comma and puts the speaker before the phrase")
    func srt() {
        let text = SubtitleWriter(Self.call, labels: Self.labels).render(.srt)
        #expect(text == """
        1
        00:00:00,500 --> 00:00:02,250
        Я: Привет, как дела?

        2
        00:00:03,000 --> 00:00:05,000
        Собеседники: Всё хорошо, спасибо.

        """)
    }

    @Test("empty and blank segments are skipped, the numbers stay in a row")
    func emptySegments() {
        let document = Self.document([
            TimedSegment(start: 0, end: 1, text: "  \n ", speaker: nil),
            TimedSegment(start: 1, end: 2, text: "Раз", speaker: nil),
            TimedSegment(start: 2, end: 3, text: "", words: [], speaker: nil),
            TimedSegment(start: 3, end: 4, text: "Два", speaker: nil),
        ])
        let writer = SubtitleWriter(document)
        let srt = writer.render(.srt)
        #expect(srt.hasPrefix("1\n00:00:01,000"))
        #expect(srt.contains("\n\n2\n00:00:03,000"))
        #expect(!srt.contains("\n3\n"))
        #expect(writer.render(.txt) == "[00:00:01] Раз\n[00:00:03] Два\n")
        #expect(SubtitleWriter(Self.document([])).render(.srt) == "")
        #expect(SubtitleWriter(Self.document([])).render(.vtt) == "WEBVTT\n")
        #expect(SubtitleWriter(Self.document([])).render(.txt) == "")
    }

    @Test("one anonymous voice shows no speaker; a name brings it back")
    func speakerVisibility() {
        let one = Self.document([TimedSegment(start: 0, end: 1, text: "Один", speaker: "speaker-1")])
        #expect(!SubtitleWriter(one, labels: Self.labels).render(.txt).contains("Спикер"))
        var named = one
        named.rename(speaker: "speaker-1", to: "Аня")
        #expect(SubtitleWriter(named, labels: Self.labels).render(.txt) == "[00:00:00] Аня: Один\n")
    }

    @Test("a renamed speaker is named everywhere; default labels use the app's language")
    func renamed() {
        var document = Self.document([
            TimedSegment(start: 0, end: 1, text: "Привет", speaker: "speaker-1"),
            TimedSegment(start: 1, end: 2, text: "Здравствуйте", speaker: "speaker-2"),
        ])
        document.rename(speaker: "speaker-2", to: "  Аня ")
        let txt = SubtitleWriter(document, labels: Self.labels).render(.txt)
        #expect(txt == "[00:00:00] Спикер 1: Привет\n[00:00:01] Аня: Здравствуйте\n")
        let vtt = SubtitleWriter(document, labels: Self.labels).render(.vtt)
        #expect(vtt.contains("<v Аня>Здравствуйте"))
        #expect(vtt.contains("<v Спикер 1>Привет"))
        #expect(SubtitleWriter(document, labels: .english).render(.txt).contains("Speaker 1: Привет"))
    }

    @Test("Unicode stays whole: emoji, combining marks, CJK")
    func unicode() {
        let document = Self.document([
            TimedSegment(start: 0, end: 2, text: "Ёлка 🎄 и é́ день 👨‍👩‍👧", speaker: nil),
            TimedSegment(start: 2, end: 4, text: "你好世界", words: [
                Self.word("你好", 2, 3), Self.word("世界", 3, 4),
            ], speaker: nil),
        ])
        let writer = SubtitleWriter(document)
        #expect(writer.render(.srt).contains("Ёлка 🎄 и é́ день 👨‍👩‍👧"))
        #expect(writer.render(.srt).contains("你好世界"))
        #expect(writer.render(.json).contains("你好"))
        #expect(!writer.render(.json).contains("\\u"))
    }

    @Test("a long phrase splits at words: lines ≤ 42, cues ≤ 7 s, none lost")
    func longPhrase() {
        let words = (0..<60).map { "слово\($0)" }
        let timed = words.enumerated().map { i, w in Self.word((i == 0 ? "" : " ") + w, Double(i), Double(i) + 0.9) }
        let document = Self.document([TimedSegment(start: 0, end: 60, text: words.joined(separator: " "), words: timed, speaker: nil)])
        let cues = SubtitleWriter(document).cues()
        #expect(cues.count > 8)
        for cue in cues {
            #expect(cue.end - cue.start <= SubtitleWriter.maxCueDuration + 1e-9)
            #expect(cue.lines.count <= SubtitleWriter.maxCueLines)
            for line in cue.lines { #expect(line.count <= SubtitleWriter.maxLineLength) }
        }
        let rejoined = cues.flatMap(\.lines).joined(separator: " ")
        #expect(rejoined == words.joined(separator: " "))
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.start <= b.start) }
    }

    @Test("a phrase without word times is shared out by length")
    func noWords() {
        let text = String(repeating: "длинное слово ", count: 30).trimmingCharacters(in: .whitespaces)
        let document = Self.document([TimedSegment(start: 10, end: 40, text: text, speaker: nil)])
        let cues = SubtitleWriter(document).cues()
        #expect(cues.count >= 5)
        #expect(cues.first?.start == 10)
        #expect(abs((cues.last?.end ?? 0) - 40) < 1e-6)
        for cue in cues {
            #expect(cue.end - cue.start <= SubtitleWriter.maxCueDuration + 1e-9)
            for line in cue.lines { #expect(line.count <= SubtitleWriter.maxLineLength) }
        }
    }

    @Test("a word longer than a line is cut by characters")
    func hugeWord() {
        let word = String(repeating: "я", count: 100)
        let document = Self.document([TimedSegment(start: 0, end: 5, text: word, speaker: nil)])
        let cues = SubtitleWriter(document).cues()
        for cue in cues { for line in cue.lines { #expect(line.count <= SubtitleWriter.maxLineLength) } }
        #expect(cues.flatMap(\.lines).joined() == word)
    }

    @Test("with a speaker the prefix counts in the first line; a long name is cut")
    func prefixLength() {
        var document = Self.document([
            TimedSegment(start: 0, end: 5, text: String(repeating: "слово ", count: 12), speaker: "speaker-1"),
            TimedSegment(start: 5, end: 6, text: "ещё", speaker: "speaker-2"),
        ])
        document.rename(speaker: "speaker-1", to: "Александр Константинович Вторичный-Третий")
        let srt = SubtitleWriter(document).render(.srt)
        for line in srt.split(separator: "\n") where !line.contains("-->") && Int(line) == nil {
            #expect(line.count <= SubtitleWriter.maxLineLength)
        }
        #expect(srt.contains("Александр Константинови…: "))
    }

    @Test("the speaker's name opens the first cue of a phrase only in SRT, every cue in VTT")
    func speakerOnSplitCues() {
        let words = (0..<30).map { "слово\($0)" }
        let timed = words.enumerated().map { i, w in Self.word((i == 0 ? "" : " ") + w, Double(i), Double(i) + 0.9) }
        var document = Self.document([
            TimedSegment(start: 0, end: 30, text: words.joined(separator: " "), words: timed, speaker: "me"),
            TimedSegment(start: 30, end: 31, text: "ок", speaker: "others"),
        ])
        document.rename(speaker: "me", to: "Я")
        let writer = SubtitleWriter(document, labels: Self.labels)
        let cues = writer.cues()
        #expect(cues.filter(\.announcesSpeaker).count == 2)
        let vtt = writer.render(.vtt)
        let tags = vtt.components(separatedBy: "<v Я>").count - 1
        let mine = cues.filter { (cue: SubtitleWriter.Cue) in cue.speaker == "Я" }.count
        #expect(tags == mine)
    }

    // MARK: VTT

    @Test("VTT: header, dots, voice tags, escaped markup")
    func vtt() {
        let document = Self.document([
            TimedSegment(start: 1, end: 2.5, text: "a < b & c > d", speaker: "me"),
            TimedSegment(start: 3, end: 4, text: "Ответ", speaker: "others"),
        ])
        let text = SubtitleWriter(document, labels: Self.labels).render(.vtt)
        #expect(text == """
        WEBVTT

        00:00:01.000 --> 00:00:02.500
        <v Я>a &lt; b &amp; c &gt; d

        00:00:03.000 --> 00:00:04.000
        <v Собеседники>Ответ

        """)
    }

    // MARK: TXT, MD

    @Test("TXT: time, speaker, text; a newline inside a phrase becomes a space")
    func txt() {
        let document = Self.document([
            TimedSegment(start: 3661, end: 3665, text: "Первая\nстрока", speaker: "me"),
            TimedSegment(start: 3670, end: 3671, text: "Ответ", speaker: "others"),
        ])
        #expect(SubtitleWriter(document, labels: Self.labels).render(.txt)
            == "[01:01:01] Я: Первая строка\n[01:01:10] Собеседники: Ответ\n")
    }

    @Test("MD: bold head, markup escaped, a title")
    func markdown() {
        let document = Self.document([TimedSegment(start: 0, end: 1, text: "*важно* [раз] a_b", speaker: "me"),
                                      TimedSegment(start: 1, end: 2, text: "ок", speaker: "others")])
        let text = SubtitleWriter(document, labels: Self.labels, title: "Созвон #1").render(.md)
        #expect(text == """
        # Созвон #1

        **[00:00:00] Я:** \\*важно\\* \\[раз\\] a\\_b

        **[00:00:01] Собеседники:** ок

        """)
    }

    // MARK: JSON

    @Test("JSON: own schema with a version, names as shown, times in milliseconds")
    func json() throws {
        var document = Self.document([
            TimedSegment(start: 0.12345, end: 1.5, text: "Привет", words: [
                Self.word("Привет", 0.12345, 1.5),
            ], speaker: "speaker-1"),
            TimedSegment(start: 2, end: 3, text: "Да", speaker: "speaker-2"),
        ])
        document.rename(speaker: "speaker-2", to: "Аня")
        let text = SubtitleWriter(document, labels: Self.labels, title: "Встреча").render(.json)
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["title"] as? String == "Встреча")
        #expect(object["language"] as? String == "ru")
        #expect(object["model"] as? String == "parakeet-tdt-v3")
        #expect(object["createdAt"] as? String == "2023-11-14T22:13:20Z")
        #expect(object["duration"] as? Double == 3)
        let speakers = try #require(object["speakers"] as? [[String: Any]])
        #expect(speakers.map { $0["name"] as? String } == ["Спикер 1", "Аня"])
        let segments = try #require(object["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments[0]["start"] as? Double == 0.123)
        #expect(segments[0]["speaker"] as? String == "speaker-1")
        #expect((segments[0]["words"] as? [[String: Any]])?.first?["text"] as? String == "Привет")
        #expect(segments[1]["words"] == nil)
        // Not a dump of the internal types.
        #expect(object["segments"] != nil && object["createdAt"] != nil && object["pendingJob"] == nil)
    }

    @Test("every format of a transcript out of order lists phrases by start")
    func order() {
        let document = Self.document([
            TimedSegment(start: 5, end: 6, text: "второе", speaker: nil),
            TimedSegment(start: 1, end: 2, text: "первое", speaker: nil),
        ])
        #expect(SubtitleWriter(document).render(.txt) == "[00:00:01] первое\n[00:00:05] второе\n")
        #expect(srtTimes(SubtitleWriter(document).render(.srt)).first == "00:00:01,000 --> 00:00:02,000")
    }

    @Test("cues of the two tracks do not overlap on screen")
    func overlappingTracks() {
        let document = Self.document([
            TimedSegment(start: 0, end: 6, text: "Длинная реплика собеседника, которая идёт долго", speaker: "others"),
            TimedSegment(start: 2, end: 3, text: "угу", speaker: "me"),
            TimedSegment(start: 2, end: 2.0004, text: "эм", speaker: "me"),
        ])
        let cues = SubtitleWriter(document, labels: Self.labels).cues()
        #expect(cues.count == 3)
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.end <= b.start + 1e-9 || a.end - a.start >= 0.001 - 1e-9)
            #expect(a.end - a.start >= 0.001 - 1e-9)
        }
        #expect(cues[0].end == 2)
        let srt = SubtitleWriter(document, labels: Self.labels).render(.srt)
        #expect(srt.contains("00:00:00,000 --> 00:00:02,000"))
    }

    @Test("a long name and a long word still fit 42 characters")
    func longNameLongWord() {
        var document = Self.document([
            TimedSegment(start: 0, end: 5, text: String(repeating: "я", count: 120), speaker: "speaker-1"),
            TimedSegment(start: 5, end: 6, text: "ещё", speaker: "speaker-2"),
        ])
        document.rename(speaker: "speaker-1", to: String(repeating: "Ж", count: 60))
        let writer = SubtitleWriter(document, labels: Self.labels)
        for cue in writer.cues() {
            for (index, line) in cue.lines.enumerated() {
                let shown = index == 0 && cue.announcesSpeaker ? (cue.speaker.map { $0.count + 2 } ?? 0) + line.count : line.count
                #expect(shown <= SubtitleWriter.maxLineLength)
            }
        }
        for line in writer.render(.srt).split(separator: "\n") where !line.contains("-->") && Int(line) == nil {
            #expect(line.count <= SubtitleWriter.maxLineLength)
        }
    }

    @Test("huge times do not trap")
    func hugeTimes() {
        #expect(SubtitleWriter.timecode(1e300, separator: ",").hasPrefix("277777"))
        #expect(SubtitleWriter.timecode(.infinity, separator: ",") == "00:00:00,000")
    }
}
