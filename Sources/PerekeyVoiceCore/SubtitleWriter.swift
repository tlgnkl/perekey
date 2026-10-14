// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The files a transcript is exported to.
public enum TranscriptFormat: String, CaseIterable, Sendable {
    case txt, md, srt, vtt, json

    public var fileExtension: String { rawValue }
}

/// The labels of speakers nobody has named, in the app's language: the core
/// has no strings of its own.
public struct SpeakerLabels: Sendable, Equatable {
    public var me: String
    public var others: String
    /// «Спикер 2» for a number.
    public var speaker: @Sendable (Int) -> String

    public init(me: String, others: String, speaker: @escaping @Sendable (Int) -> String) {
        self.me = me
        self.others = others
        self.speaker = speaker
    }

    public static let english = SpeakerLabels(me: "Me", others: "Others", speaker: { "Speaker \($0)" })

    public static func == (lhs: SpeakerLabels, rhs: SpeakerLabels) -> Bool {
        lhs.me == rhs.me && lhs.others == rhs.others && lhs.speaker(1) == rhs.speaker(1)
    }

    /// What a speaker is called: the user's name, or the default label.
    public func name(of speaker: TranscriptSpeaker) -> String {
        if let name = speaker.name, !name.isEmpty { return name }
        switch speaker.kind {
        case .me: return me
        case .others: return others
        case .speaker: return self.speaker(speaker.number ?? 0)
        }
    }
}

/// `TranscriptDocument` → TXT, Markdown, SRT, WebVTT and JSON. A pure
/// function of the document: times are on the recording's scale, which has
/// no pauses, so a subtitle file lines up with the audio the way the
/// transcript does.
public struct SubtitleWriter: Sendable {
    /// Longest line of a subtitle, speaker's prefix included.
    public static let maxLineLength = 42
    /// Longest time a subtitle stays on the screen.
    public static let maxCueDuration = 7.0
    /// Lines in one subtitle.
    public static let maxCueLines = 2
    /// A speaker's name longer than this is cut in subtitles, so that a line has room for words.
    static let maxPrefixLength = 24
    /// The JSON file's own schema, apart from `TranscriptDocument`'s.
    public static let jsonSchemaVersion = 1

    public let document: TranscriptDocument
    public let labels: SpeakerLabels
    /// A heading for Markdown and JSON, usually the recording's name.
    public let title: String?

    public init(_ document: TranscriptDocument, labels: SpeakerLabels = .english, title: String? = nil) {
        self.document = document
        self.labels = labels
        self.title = title
    }

    public func render(_ format: TranscriptFormat) -> String {
        switch format {
        case .txt: text()
        case .md: markdown()
        case .srt: subRip()
        case .vtt: webVTT()
        case .json: json()
        }
    }

    // MARK: Segments and speakers

    /// Phrases with text, in order of their start.
    var phrases: [TimedSegment] {
        let kept = document.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return kept.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// Speakers show up when there is more than one, or when someone is named:
    /// a file with one anonymous voice is just text.
    private var showsSpeakers: Bool {
        document.speakers.count > 1 || document.speakers.contains { $0.name != nil }
    }

    private func speakerName(_ id: String?) -> String? {
        guard showsSpeakers, let id, let speaker = document.speakers.first(where: { $0.id == id }) else { return nil }
        return labels.name(of: speaker)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Times

    /// `HH:MM:SS` + `separator` + `mmm`. Milliseconds are rounded once and
    /// split as integers: 3599.9996 s is 01:00:00, not 00:59:60.
    static func timecode(_ seconds: Double, separator: String) -> String {
        let total = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        let ms = total % 1000
        let s = total / 1000 % 60
        let m = total / 60_000 % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    private static func stamp(_ seconds: Double) -> String {
        String(timecode(seconds, separator: ".").dropLast(4))
    }

    // MARK: TXT and Markdown

    private func text() -> String {
        var lines: [String] = []
        for phrase in phrases {
            let prefix = speakerName(phrase.speaker).map { "\($0): " } ?? ""
            lines.append("[\(Self.stamp(phrase.start))] \(prefix)\(Self.oneLine(phrase.text))")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func markdown() -> String {
        var blocks: [String] = []
        if let title, !title.isEmpty { blocks.append("# \(Self.escapeMarkdown(Self.oneLine(title)))") }
        for phrase in phrases {
            let head = "[\(Self.stamp(phrase.start))]" + (speakerName(phrase.speaker).map { " \(Self.escapeMarkdown($0)):" } ?? "")
            blocks.append("**\(head)** \(Self.escapeMarkdown(Self.oneLine(phrase.text)))")
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\*_`[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: SRT and WebVTT

    /// One subtitle.
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var speaker: String?
        /// The speaker's name goes before the first line of the segment's first cue.
        var announcesSpeaker: Bool
        var lines: [String]
    }

    /// A word to place: its text without the space before, and whether there was one.
    private struct Piece {
        var start: Double
        var end: Double
        var text: String
        var spaceBefore: Bool
    }

    private func pieces(of phrase: TimedSegment) -> [Piece] {
        let limit = Self.maxLineLength - 1
        var result: [Piece] = []
        func add(_ start: Double, _ stop: Double, _ raw: String, spaced: Bool) {
            let stop = max(start, stop)
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return }
            let space = spaced || raw.first?.isWhitespace == true
            // A word that cannot fit a line is cut by characters, its time shared by length.
            let characters = Array(word)
            guard characters.count > limit else {
                result.append(Piece(start: start, end: stop, text: word, spaceBefore: space))
                return
            }
            let chunks = stride(from: 0, to: characters.count, by: limit).map { String(characters[$0..<min($0 + limit, characters.count)]) }
            let duration = stop - start
            var from = start
            for (index, chunk) in chunks.enumerated() {
                let to = from + duration * Double(chunk.count) / Double(characters.count)
                result.append(Piece(start: from, end: to, text: chunk, spaceBefore: index == 0 ? space : false))
                from = to
            }
        }
        if let words = phrase.words, words.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            for word in words { add(word.start, word.end, word.text, spaced: false) }
        } else {
            // Only the phrase has times: the words get their share by length.
            let words = Self.oneLine(phrase.text).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let total = max(1, words.reduce(0) { $0 + $1.count })
            let duration = max(0, phrase.end - phrase.start)
            var from = phrase.start
            for (index, word) in words.enumerated() {
                let to = from + duration * Double(word.count) / Double(total)
                add(from, to, word, spaced: index > 0)
                from = to
            }
        }
        return result
    }

    private static func render(_ pieces: ArraySlice<Piece>) -> String {
        var line = ""
        for piece in pieces {
            if piece.spaceBefore, !line.isEmpty { line += " " }
            line += piece.text
        }
        return line
    }

    /// Breaks pieces into lines of at most `limit` characters, the first one
    /// with `indent` taken by the speaker's name. Nil when they need more
    /// than `maxCueLines`.
    private static func wrap(_ pieces: [Piece], indent: Int) -> [String]? {
        var lines: [String] = []
        var from = 0
        var limit = maxLineLength - indent
        while from < pieces.count {
            var to = from + 1
            while to < pieces.count, render(pieces[from...to]).count <= limit { to += 1 }
            guard render(pieces[from..<to]).count <= limit || to - from == 1 else { return nil }
            lines.append(render(pieces[from..<to]))
            from = to
            limit = maxLineLength
            if lines.count > maxCueLines { return nil }
        }
        return lines.count <= maxCueLines ? lines : nil
    }

    func cues() -> [Cue] {
        var cues: [Cue] = []
        for phrase in phrases {
            let name = speakerName(phrase.speaker)
            var prefix: String?
            if let name {
                let shown = name.count > Self.maxPrefixLength ? String(name.prefix(Self.maxPrefixLength - 1)) + "…" : name
                prefix = shown
            }
            let indent = prefix.map { $0.count + 2 } ?? 0
            var current: [Piece] = []
            var first = true
            func flush() {
                guard let start = current.first?.start, let end = current.last?.end else { return }
                let lines = Self.wrap(current, indent: first ? indent : 0) ?? [Self.render(current[...])]
                cues.append(Cue(start: start, end: max(end, start + 0.001), speaker: prefix, announcesSpeaker: first, lines: lines))
                current = []
                first = false
            }
            for piece in pieces(of: phrase) {
                if let start = current.first?.start {
                    let candidate = current + [piece]
                    let fits = piece.end - start <= Self.maxCueDuration
                        && Self.wrap(candidate, indent: first ? indent : 0) != nil
                    if !fits { flush() }
                }
                current.append(piece)
            }
            flush()
        }
        return cues
    }

    private func subRip() -> String {
        var blocks: [String] = []
        for (index, cue) in cues().enumerated() {
            var lines = cue.lines
            if cue.announcesSpeaker, let speaker = cue.speaker, !lines.isEmpty { lines[0] = "\(speaker): \(lines[0])" }
            blocks.append("\(index + 1)\n\(Self.timecode(cue.start, separator: ",")) --> \(Self.timecode(cue.end, separator: ","))\n"
                + lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
    }

    private func webVTT() -> String {
        var blocks = ["WEBVTT"]
        for cue in cues() {
            var body = cue.lines.map(Self.escapeVTT).joined(separator: "\n")
            if let speaker = cue.speaker {
                body = "<v \(Self.escapeVTT(speaker))>" + body
            }
            blocks.append("\(Self.timecode(cue.start, separator: ".")) --> \(Self.timecode(cue.end, separator: "."))\n\(body)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: JSON

    private struct JSONFile: Encodable {
        struct Speaker: Encodable {
            var id: String
            var name: String
        }

        struct Word: Encodable {
            var start: Double
            var end: Double
            var text: String
        }

        struct Segment: Encodable {
            var start: Double
            var end: Double
            var speaker: String?
            var text: String
            var words: [Word]?
        }

        var schemaVersion: Int
        var title: String?
        var language: String?
        var model: String
        var engine: String
        var createdAt: Date
        var duration: Double
        var speakers: [Speaker]
        var segments: [Segment]
    }

    private func json() -> String {
        func ms(_ value: Double) -> Double { (max(0, value) * 1000).rounded() / 1000 }
        let segments = phrases.map { phrase in
            JSONFile.Segment(
                start: ms(phrase.start), end: ms(phrase.end), speaker: phrase.speaker,
                text: Self.oneLine(phrase.text),
                words: phrase.words.map { words in
                    words.compactMap { word in
                        let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : JSONFile.Word(start: ms(word.start), end: ms(word.end), text: text)
                    }
                })
        }
        let file = JSONFile(
            schemaVersion: Self.jsonSchemaVersion, title: title.flatMap { $0.isEmpty ? nil : $0 },
            language: document.language, model: document.model, engine: document.engine,
            createdAt: document.createdAt, duration: ms(segments.map(\.end).max() ?? 0),
            speakers: document.speakers.map { JSONFile.Speaker(id: $0.id, name: labels.name(of: $0)) },
            segments: segments)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(file)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
