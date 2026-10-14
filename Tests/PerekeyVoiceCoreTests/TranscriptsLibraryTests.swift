// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyVoiceCore
import Testing

struct TranscriptsLibraryTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "perekey-library-\(UUID().uuidString)")
        let queue = FakeFileQueue()
        var folder: RecordingsFolder { RecordingsFolder(root: root) }
        func library(queue: Bool = true) -> TranscriptsLibrary {
            TranscriptsLibrary(folder: folder, queue: queue ? self.queue : nil)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func add(_ meta: RecordingMeta, transcript: TranscriptDocument? = nil) throws -> UUID {
            let id = try folder.create(meta, excludedFromBackup: true)
            if let transcript { try folder.updateTranscript(id) { $0 = transcript } }
            return id
        }
    }

    static func document() -> TranscriptDocument {
        TranscriptDocument(model: "parakeet-tdt-v3", engine: "parakeet", language: "ru", segments: [
            TimedSegment(start: 0, end: 1, text: "Привет", speaker: "me"),
            TimedSegment(start: 1, end: 2, text: "Здравствуйте", speaker: "speaker-2"),
        ])
    }

    @Test func listIsNewestFirstAndKnowsTranscripts() throws {
        let fixture = Fixture()
        let old = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3"), createdAt: Date(timeIntervalSince1970: 100)))
        let new = try fixture.add(RecordingMeta.file(FileReference(path: "/b.mp3"), createdAt: Date(timeIntervalSince1970: 200)),
                                  transcript: Self.document())
        let items = fixture.library().items()
        #expect(items.map(\.id) == [new, old])
        #expect(items.map(\.status) == [.done, .untranscribed])
        #expect(items.map(\.hasTranscript) == [true, false])
    }

    @Test func phasesAndLiveRecordingsChangeStatuses() throws {
        let fixture = Fixture()
        let call = try fixture.add(TranscriptsModelTests.call(state: .recording))
        let file = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")))
        let items = fixture.library().items(phases: [file: .transcribing(0.34)], live: [])
        #expect(items.first { $0.id == call }?.status == .interrupted)
        #expect(items.first { $0.id == file }?.status == .transcribing(0.34))
        let live = fixture.library().items(live: [call])
        #expect(live.first { $0.id == call }?.status == .recording)
        // A phase moves one item without reading the disk again.
        #expect(items.first { $0.id == file }?.with(phase: .done, isLive: false).status == .untranscribed)
    }

    @Test func foldersWithoutAMetaAreNotShown() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.folder.directory(for: UUID()), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "not-a-uuid"), withIntermediateDirectories: true)
        #expect(fixture.library().items().isEmpty)
    }

    @Test func renamingASpeakerGoesThroughTheTranscriptFile() throws {
        let fixture = Fixture()
        let id = try fixture.add(TranscriptsModelTests.call(), transcript: Self.document())
        try fixture.library().rename(speaker: "speaker-2", to: " Аня ", in: id)
        try fixture.library().rename(speaker: "me", to: "Сергей", in: id)
        guard case let .loaded(document) = fixture.folder.transcript(id) else { Issue.record("no transcript"); return }
        #expect(document.speakers.first { $0.id == "speaker-2" }?.name == "Аня")
        #expect(document.speakers.first { $0.id == "me" }?.name == "Сергей")
        try fixture.library().rename(speaker: "speaker-2", to: "  ", in: id)
        guard case let .loaded(reset) = fixture.folder.transcript(id) else { Issue.record("no transcript"); return }
        #expect(reset.speakers.first { $0.id == "speaker-2" }?.name == nil)
        // No transcript: there is nobody to rename, and nothing is written.
        let bare = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")))
        try fixture.library().rename(speaker: "me", to: "X", in: bare)
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.transcriptURL(for: bare).path))
    }

    @Test func retranscribeQueuesAJobWithTheChosenModel() async throws {
        let fixture = Fixture()
        let id = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")), transcript: Self.document())
        try await fixture.library().retranscribe(id, model: "whisper-large-v3-turbo", diarize: true)
        #expect(fixture.queue.jobs == [TranscriptionJob(recording: id, model: "whisper-large-v3-turbo", diarize: true)])
        await #expect(throws: TranscriptsLibraryError.queueUnavailable) {
            try await fixture.library(queue: false).retranscribe(id, model: "x", diarize: false)
        }
    }

    @Test func resumeClosesACutOffRecordingAndQueuesIt() async throws {
        let fixture = Fixture()
        let id = try fixture.add(TranscriptsModelTests.call(state: .recording))
        try await fixture.library().resume(id, model: "parakeet-tdt-v3", diarize: false,
                                           now: Date().addingTimeInterval(120))
        guard case let .loaded(meta) = fixture.folder.meta(id) else { Issue.record("no meta"); return }
        #expect(meta.state == .stopped)
        #expect(fixture.queue.jobs.map(\.recording) == [id])
    }

    @Test func deleteStopsTheJobAndRemovesTheFolder() async throws {
        let fixture = Fixture()
        let running = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")))
        let idle = try fixture.add(RecordingMeta.file(FileReference(path: "/b.mp3")), transcript: Self.document())
        try await fixture.library().delete(running, phase: .transcribing(0.5))
        try await fixture.library().delete(idle, phase: .done)
        #expect(fixture.queue.cancelled == [running])
        #expect(fixture.folder.recordings().isEmpty)
    }

    @Test func deleteAllLeavesTheRecordingThatRunsNow() async throws {
        let fixture = Fixture()
        let live = try fixture.add(TranscriptsModelTests.call(state: .recording))
        let one = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")))
        let two = try fixture.add(RecordingMeta.file(FileReference(path: "/b.mp3")))
        let failed = await fixture.library().deleteAll(phases: [one: .queued], live: [live])
        #expect(failed == 0)
        #expect(fixture.folder.recordings() == [live])
        #expect(fixture.queue.cancelled == [one])
        _ = two
    }

    @Test func aDroppedFileGetsABookmarkAndIsQueuedWithoutACopy() async throws {
        let fixture = Fixture()
        let source = FileManager.default.temporaryDirectory.appending(path: "perekey-drop-\(UUID().uuidString).m4a")
        try Data(count: 1_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let id = try await fixture.library().add(file: source, model: "parakeet-tdt-v3", diarize: false, excludedFromBackup: true)
        guard case let .loaded(meta) = fixture.folder.meta(id) else { Issue.record("no meta"); return }
        #expect(meta.kind == .file)
        #expect(meta.source.file?.path == source.path)
        #expect(meta.source.file?.bookmark != nil)
        #expect(fixture.queue.jobs.map(\.recording) == [id])
        let inside = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.directory(for: id).path)
        #expect(inside == ["meta.json"])
        await #expect(throws: TranscriptsLibraryError.queueUnavailable) {
            try await fixture.library(queue: false).add(file: source, model: "x", diarize: false, excludedFromBackup: true)
        }
        #expect(fixture.folder.recordings() == [id])
    }

    @Test func resumeLeavesARecordingThatWroteItsMetaJustNow() async throws {
        let fixture = Fixture()
        let id = try fixture.add(TranscriptsModelTests.call(state: .recording))
        await #expect(throws: TranscriptsLibraryError.recordingInProgress) {
            try await fixture.library().resume(id, model: "x", diarize: false)
        }
        guard case let .loaded(meta) = fixture.folder.meta(id) else { Issue.record("no meta"); return }
        #expect(meta.state == .recording)
        #expect(fixture.queue.jobs.isEmpty)
    }

    @Test func deleteLeavesARecordingThatWroteItsMetaJustNow() async throws {
        let fixture = Fixture()
        let id = try fixture.add(TranscriptsModelTests.call(state: .recording))
        await #expect(throws: TranscriptsLibraryError.recordingInProgress) {
            try await fixture.library().delete(id, phase: nil)
        }
        #expect(fixture.folder.recordings() == [id])
        // A recording that has been silent for a while is a crashed one, and can go.
        try await fixture.library().delete(id, phase: nil, now: Date().addingTimeInterval(120))
        #expect(fixture.folder.recordings().isEmpty)
    }

    @Test func deleteRefusesALiveRecording() async throws {
        let fixture = Fixture()
        let id = try fixture.add(TranscriptsModelTests.call(state: .recording))
        await #expect(throws: TranscriptsLibraryError.recordingInProgress) {
            try await fixture.library().delete(id, phase: nil, live: [id])
        }
        #expect(fixture.folder.recordings() == [id])
    }

    @Test func deleteKeepsTheFolderWhenTheQueueDoesNotStop() async throws {
        let fixture = Fixture()
        let id = try fixture.add(RecordingMeta.file(FileReference(path: "/a.mp3")))
        /// A queue that never stops what it runs.
        final class Running: FileTranscribing {
            let id: UUID
            init(_ id: UUID) { self.id = id }
            func enqueue(_ job: TranscriptionJob) async {}
            func cancel(_ recording: UUID) async {}
            func phases() -> AsyncStream<[UUID: TranscriptionPhase]> {
                let id = id
                return AsyncStream { $0.yield([id: .transcribing(0.5)]) }
            }
            var isBusy: Bool { true }
        }
        let library = TranscriptsLibrary(folder: fixture.folder, queue: Running(id), cancelTimeout: .milliseconds(200))
        await #expect(throws: TranscriptsLibraryError.cancelTimedOut) {
            try await library.delete(id, phase: .transcribing(0.5))
        }
        #expect(fixture.folder.recordings() == [id])
    }
}
