// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore
import Testing

struct RecordingTests {
    final class Fixture {
        let root = URL.temporaryDirectory.appending(path: "perekey-recordings-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        var folder: RecordingsFolder { RecordingsFolder(root: root) }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func call() -> RecordingMeta {
        var meta = RecordingMeta.call(source: .app(bundleID: "us.zoom.xos", name: "zoom.us"), startHostTime: 7_068_968,
                                      createdAt: date, audioRetention: .always)
        meta.segments = [
            .init(track: .sys, file: "sys-0002.aac", startHostTime: 9, startOffset: 300.4, frames: 0, closed: false),
            .init(track: .sys, file: "sys-0001.aac", startHostTime: 8, startOffset: 0.19, frames: 4_800_000,
                  closed: true),
            .init(track: .mic, file: "mic-0001.aac", startHostTime: 7, startOffset: 0, frames: 4_800_000, closed: true),
        ]
        meta.gaps = [.init(track: .sys, startOffset: 9.01, reason: "deviceChanged")]
        return meta
    }

    @Test func segmentNames() {
        #expect(RecordingMeta.Segment.fileName(track: .mic, number: 1) == "mic-0001.aac")
        #expect(RecordingMeta.Segment.fileName(track: .sys, number: 42) == "sys-0042.aac")
        #expect(RecordingMeta.adtsPrimingFrames == 2112)
    }

    /// Segments are read by their own starts; one a crash left open is read to its end.
    @Test func trackAudio() throws {
        let meta = Self.call()
        let directory = URL(filePath: "/r/", directoryHint: .isDirectory)
        #expect(meta.tracks == [.mic, .sys])
        let audio = try #require(meta.audio(of: .sys, in: directory))
        #expect(audio == .track(.sys, [
            TrackSegment(path: "/r/sys-0001.aac", startOffset: 0.19, frames: 4_800_000),
            TrackSegment(path: "/r/sys-0002.aac", startOffset: 300.4, frames: nil),
        ]))
        #expect(meta.audio(in: directory) == nil)
        let file = FileReference(path: "/Users/a/talk.mp3", bookmark: Data([1, 2]))
        #expect(RecordingMeta.file(file).audio(in: directory) == .file(file))
    }

    @Test func metaRoundTrip() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        guard case let .loaded(meta) = fixture.folder.meta(id) else {
            Issue.record("not loaded")
            return
        }
        #expect(meta == Self.call())
        let json = try String(contentsOf: fixture.folder.metaURL(for: id), encoding: .utf8)
        #expect(json.contains("\"format\" : \"adts\""))
        #expect(json.contains("\"state\" : \"recording\""))
        #expect(json.contains("\"track\" : \"sys\""))
        #expect(json.contains("\"createdAt\" : \"2027-01-15T08:00:00Z\""))
    }

    /// The prototype's `meta.json`, with the keys the product added, reads.
    @Test func metaReadsWithoutOptionalKeys() throws {
        let fixture = Fixture()
        let id = UUID()
        try FileManager.default.createDirectory(at: fixture.folder.directory(for: id), withIntermediateDirectories: true)
        try Data("""
        { "schemaVersion": 1, "kind": "call", "source": { "kind": "system" }, "createdAt": "2027-01-15T08:00:00Z",
          "state": "stopped", "format": "adts", "startHostTime": 7068968 }
        """.utf8).write(to: fixture.folder.metaURL(for: id))
        guard case let .loaded(meta) = fixture.folder.meta(id) else {
            Issue.record("not loaded")
            return
        }
        #expect(meta.source == .system)
        #expect(meta.segments.isEmpty && meta.gaps.isEmpty)
        #expect(meta.sampleRate == 16_000)
    }

    @Test func newerMetaIsNeverWritten() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        let newer = Data(#"{ "schemaVersion": 2, "kind": "call", "wholeNewThing": true }"#.utf8)
        try newer.write(to: fixture.folder.metaURL(for: id))
        guard case .newer(schemaVersion: 2) = fixture.folder.meta(id) else {
            Issue.record("not seen as newer")
            return
        }
        #expect(throws: RecordingsFolder.NewerVersionError(schemaVersion: 2)) {
            try fixture.folder.save(Self.call(), id: id)
        }
        #expect(try Data(contentsOf: fixture.folder.metaURL(for: id)) == newer)
    }

    /// A newer Perekey's key in the same schema stays in `meta.json`.
    @Test func unknownMetaKeysStay() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.folder.metaURL(for: id))) as? [String: Any])
        object["level"] = 3
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.folder.metaURL(for: id))
        var meta = Self.call()
        meta.state = .stopped
        try fixture.folder.save(meta, id: id)
        let saved = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.folder.metaURL(for: id))) as? [String: Any])
        #expect(saved["level"] as? Int == 3)
        #expect(saved["state"] as? String == "stopped")
    }

    @Test func unreadableAndMissing() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        guard case .missing = fixture.folder.transcript(id) else {
            Issue.record("transcript should be missing")
            return
        }
        try Data("{".utf8).write(to: fixture.folder.metaURL(for: id))
        guard case .unreadable = fixture.folder.meta(id) else {
            Issue.record("should be unreadable")
            return
        }
        #expect(fixture.folder.recordings() == [id])
    }

    @Test func newFolderIsKeptOutOfTimeMachine() throws {
        let fixture = Fixture()
        try fixture.folder.create(Self.call())
        #expect(fixture.folder.isExcludedFromBackup)
        try fixture.folder.setExcludedFromBackup(false)
        try fixture.folder.create(Self.call())
        #expect(!fixture.folder.isExcludedFromBackup)
    }

    static func transcript(model: String = "parakeet-tdt-0.6b-v3") -> TranscriptDocument {
        TranscriptDocument(model: model, engine: "parakeet", language: "ru", createdAt: date, segments: [
            TimedSegment(start: 0.5, end: 1.2, text: "Привет.", words: [TimedWord(start: 0.5, end: 1.2, text: " Привет.")],
                         speaker: "me"),
            TimedSegment(start: 1.4, end: 2, text: "Здравствуйте.", speaker: "speaker-1"),
            TimedSegment(start: 2.1, end: 3, text: "Да.", speaker: "speaker-2"),
            TimedSegment(start: 3.1, end: 4, text: "Ага.", speaker: "speaker-1"),
        ])
    }

    @Test func speakersInOrderOfAppearance() {
        let document = Self.transcript()
        #expect(document.speakers == [.me, .speaker(1), .speaker(2)])
        #expect(TranscriptDocument.speakers(of: [TimedSegment(start: 0, end: 1, text: "x", speaker: "others")])
            == [.others])
    }

    @Test func transcriptRoundTrip() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        var document = Self.transcript()
        document.rename(speaker: "speaker-2", to: "  Аня ")
        try fixture.folder.save(document, id: id)
        guard case let .loaded(loaded) = fixture.folder.transcript(id) else {
            Issue.record("not loaded")
            return
        }
        #expect(loaded == document)
        #expect(loaded.speakers[2].name == "Аня")
        let json = try String(contentsOf: fixture.folder.transcriptURL(for: id), encoding: .utf8)
        for key in ["schemaVersion", "model", "engine", "language", "createdAt", "segments", "speakers"] {
            #expect(json.contains("\"\(key)\""))
        }
    }

    @Test func renameToNothingBringsBackTheDefault() {
        var document = Self.transcript()
        document.rename(speaker: "me", to: "Олег")
        document.rename(speaker: "me", to: " ")
        #expect(document.speakers[0].name == nil)
        document.rename(speaker: "nobody", to: "X")
        #expect(document.speakers == Self.transcript().speakers)
    }

    /// «Расшифровать заново»: «Я» and «Собеседники» keep their names, voices
    /// found anew lose theirs.
    @Test func retranscribeKeepsOnlyTrackNames() {
        var old = Self.transcript()
        old.rename(speaker: "me", to: "Олег")
        old.rename(speaker: "speaker-1", to: "Аня")
        var new = Self.transcript(model: "whisper-large-v3-turbo")
        new.segments.append(TimedSegment(start: 5, end: 6, text: "x", speaker: "others"))
        new.speakers = TranscriptDocument.speakers(of: new.segments)
        let kept = new.keepingNames(from: old)
        #expect(kept.speakers.first { $0.id == "me" }?.name == "Олег")
        #expect(kept.speakers.first { $0.id == "speaker-1" }?.name == nil)
        #expect(kept.speakers.first { $0.id == "others" }?.name == nil)
        #expect(kept.model == "whisper-large-v3-turbo")
    }

    @Test func newerTranscriptIsNeverWritten() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        try Data(#"{ "schemaVersion": 7 }"#.utf8).write(to: fixture.folder.transcriptURL(for: id))
        #expect(throws: RecordingsFolder.NewerVersionError(schemaVersion: 7)) {
            try fixture.folder.save(Self.transcript(), id: id)
        }
    }

    @Test func removeTakesTheFolder() throws {
        let fixture = Fixture()
        let id = try fixture.folder.create(Self.call())
        try fixture.folder.remove(id)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.directory(for: id).path))
    }

    @Test func shiftMovesWordsToo() {
        let segment = TimedSegment(start: 1, end: 2, text: "a", words: [TimedWord(start: 1, end: 2, text: "a")])
            .shifted(by: 60)
        #expect(segment.start == 61 && segment.end == 62)
        #expect(segment.words == [TimedWord(start: 61, end: 62, text: "a")])
    }
}

struct DictationActivityTests {
    @Test func idleReturnsAtOnceWithoutDictation() async {
        await DictationActivity().idle()
    }

    @Test func idleWaitsForTheEnd() async {
        let activity = DictationActivity()
        activity.began()
        #expect(activity.isActive)
        let waiter = Task {
            await activity.idle()
            return !activity.isActive
        }
        try? await Task.sleep(for: .milliseconds(20))
        activity.ended()
        #expect(await waiter.value)
    }

    @Test func phases() {
        #expect(TranscriptionPhase.waitingForDictation(0.4).isPending)
        #expect(TranscriptionPhase.preparingModel.isPending)
        #expect(!TranscriptionPhase.failed(.sourceMissing).isPending)
        #expect(!TranscriptionPhase.cancelled.isPending)
    }
}
