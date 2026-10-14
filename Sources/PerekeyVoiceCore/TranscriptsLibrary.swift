// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A recording as the «Расшифровки» list holds it.
public struct RecordingItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var meta: RecordingMeta
    public var hasTranscript: Bool
    public var status: RecordingStatus
    public var capabilities: RecordingCapabilities

    public init(id: UUID, meta: RecordingMeta, hasTranscript: Bool, phase: TranscriptionPhase?, isLive: Bool) {
        self.id = id
        self.meta = meta
        self.hasTranscript = hasTranscript
        let status = RecordingStatus.of(meta: meta, hasTranscript: hasTranscript, phase: phase, isLive: isLive)
        self.status = status
        capabilities = RecordingCapabilities(meta: meta, hasTranscript: hasTranscript, status: status)
    }

    public var title: RecordingTitle { RecordingTitle(meta) }
    public var createdAt: Date { meta.createdAt }
    /// Seconds on the recording's scale, when `meta.json` knows them.
    public var duration: Double? { meta.duration }

    /// The same recording after the queue's phase changed.
    public func with(phase: TranscriptionPhase?, isLive: Bool) -> RecordingItem {
        RecordingItem(id: id, meta: meta, hasTranscript: hasTranscript, phase: phase, isLive: isLive)
    }
}

public enum TranscriptsLibraryError: Error, Equatable {
    /// The file queue is not there (yet): nothing can be queued.
    case queueUnavailable
}

/// What the window does to recordings on disk and in the queue, without any
/// AppKit: the list, the speakers' names, «Расшифровать заново», deleting and
/// adding a file. The window's controller holds the state and the UI.
public struct TranscriptsLibrary: Sendable {
    public let folder: RecordingsFolder
    public let queue: (any FileTranscribing)?

    public init(folder: RecordingsFolder = RecordingsFolder(), queue: (any FileTranscribing)?) {
        self.folder = folder
        self.queue = queue
    }

    /// The recordings on disk, the newest first. A folder whose `meta.json`
    /// is missing or unreadable is not shown; one of a newer Perekey is left
    /// alone and is not shown either.
    public func items(phases: [UUID: TranscriptionPhase] = [:], live: Set<UUID> = []) -> [RecordingItem] {
        folder.recordings().compactMap { id -> RecordingItem? in
            guard case let .loaded(meta) = folder.meta(id) else { return nil }
            let hasTranscript = FileManager.default.fileExists(atPath: folder.transcriptURL(for: id).path)
            return RecordingItem(id: id, meta: meta, hasTranscript: hasTranscript, phase: phases[id],
                                 isLive: live.contains(id))
        }
        .sorted { ($0.createdAt, $1.id.uuidString) > ($1.createdAt, $0.id.uuidString) }
    }

    /// «Спикер 2» → «Аня»; nil or blank brings back the default label.
    /// Goes through `updateTranscript`, so a new transcript the queue writes
    /// meanwhile does not lose the name of «Я» or «Собеседники».
    public func rename(speaker: String, to name: String?, in recording: UUID) throws {
        try folder.updateTranscript(recording) { document in
            document?.rename(speaker: speaker, to: name)
        }
    }

    /// «Расшифровать заново» with another model. The queue keeps the names of
    /// «Я» and «Собеседники» and drops the others.
    public func retranscribe(_ recording: UUID, model: String, diarize: Bool, language: String? = nil) async throws {
        guard let queue else { throw TranscriptsLibraryError.queueUnavailable }
        await queue.enqueue(TranscriptionJob(recording: recording, model: model, diarize: diarize, language: language))
    }

    /// «Запись прервалась · Расшифровать»: the crash left the recording
    /// `recording`; it is closed as it is, and its audio is queued.
    public func resume(_ recording: UUID, model: String, diarize: Bool) async throws {
        guard let queue else { throw TranscriptsLibraryError.queueUnavailable }
        try folder.updateMeta(recording) { meta in
            if meta.state == .recording { meta.state = .stopped }
        }
        await queue.enqueue(TranscriptionJob(recording: recording, model: model, diarize: diarize))
    }

    /// Stops the recording's job if it runs, and removes its folder. A file
    /// the user chose is outside it and stays.
    public func delete(_ recording: UUID, phase: TranscriptionPhase?) async throws {
        if phase?.isPending == true { await queue?.cancel(recording) }
        try folder.remove(recording)
    }

    /// Removes every recording but those still being recorded; returns how
    /// many could not be removed.
    @discardableResult
    public func deleteAll(phases: [UUID: TranscriptionPhase] = [:], live: Set<UUID> = []) async -> Int {
        var failed = 0
        for id in folder.recordings() where !live.contains(id) {
            do {
                try await delete(id, phase: phases[id])
            } catch {
                failed += 1
            }
        }
        return failed
    }

    /// A file the user dropped: a recording with a bookmark, queued at once.
    /// The file is never copied.
    @discardableResult
    public func add(file url: URL, model: String, diarize: Bool, excludedFromBackup: Bool) async throws -> UUID {
        guard let queue else { throw TranscriptsLibraryError.queueUnavailable }
        let reference = FileReference(path: url.path, bookmark: try? url.bookmarkData())
        let id = try folder.create(.file(reference), excludedFromBackup: excludedFromBackup)
        await queue.enqueue(TranscriptionJob(recording: id, model: model, diarize: diarize))
        return id
    }

    /// How much room recordings take on disk.
    public func diskUsage() -> Int64 { RecordingsDiskUsage.bytes(in: folder.root) }
}
