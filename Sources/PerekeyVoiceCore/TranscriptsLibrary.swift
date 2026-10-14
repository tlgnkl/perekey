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
    /// A recording a recorder is still writing: it is not closed from here.
    case recordingInProgress
    /// The queue did not stop the recording's job in time; its folder is left alone.
    case cancelTimedOut
}

/// What the window does to recordings on disk and in the queue, without any
/// AppKit: the list, the speakers' names, «Расшифровать заново», deleting and
/// adding a file. The window's controller holds the state and the UI.
public struct TranscriptsLibrary: Sendable {
    public let folder: RecordingsFolder
    public let queue: (any FileTranscribing)?
    /// How long a delete waits for the queue to stop a job.
    public let cancelTimeout: Duration

    public init(folder: RecordingsFolder = RecordingsFolder(), queue: (any FileTranscribing)?,
                cancelTimeout: Duration = .seconds(10)) {
        self.folder = folder
        self.queue = queue
        self.cancelTimeout = cancelTimeout
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
    ///
    /// The recorder rewrites `meta.json` while it records. When `live` is not
    /// wired (the recorder reports its recordings there), a `recording` whose
    /// `meta.json` changed less than `liveWithin` seconds ago is taken as
    /// still going, and is left alone.
    public func resume(_ recording: UUID, model: String, diarize: Bool, now: Date = Date(),
                       liveWithin: TimeInterval = 60) async throws
    {
        guard let queue else { throw TranscriptsLibraryError.queueUnavailable }
        guard !isGoingOn(recording, now: now, liveWithin: liveWithin) else { throw TranscriptsLibraryError.recordingInProgress }
        try folder.updateMeta(recording) { meta in
            if meta.state == .recording { meta.state = .stopped }
        }
        await queue.enqueue(TranscriptionJob(recording: recording, model: model, diarize: diarize))
    }

    /// Stops the recording's job if it runs, and removes its folder. A file
    /// the user chose is outside it and stays.
    public func delete(_ recording: UUID, phase: TranscriptionPhase?, live: Set<UUID> = [], now: Date = Date(),
                       liveWithin: TimeInterval = 60) async throws
    {
        guard !live.contains(recording), !isGoingOn(recording, now: now, liveWithin: liveWithin) else {
            throw TranscriptsLibraryError.recordingInProgress
        }
        if phase?.isPending == true, let queue {
            await queue.cancel(recording)
            // The queue writes into the folder until it has stopped: wait for it.
            guard await Self.settled(recording, in: queue, timeout: cancelTimeout) else {
                throw TranscriptsLibraryError.cancelTimedOut
            }
        }
        try folder.remove(recording)
    }

    /// True once the queue reports the recording as no longer pending.
    private static func settled(_ recording: UUID, in queue: any FileTranscribing, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await snapshot in await queue.phases() where snapshot[recording]?.isPending != true { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Removes every recording but those still being recorded; returns how
    /// many could not be removed.
    /// Whether a recorder looks to be writing the recording: `recording` in its
    /// `meta.json`, which changed less than `liveWithin` seconds ago. The check
    /// of `resume` and `delete` while the recorder does not report its recordings.
    private func isGoingOn(_ recording: UUID, now: Date, liveWithin: TimeInterval) -> Bool {
        guard case let .loaded(meta) = folder.meta(recording), meta.state == .recording,
              let modified = try? FileManager.default.attributesOfItem(atPath: folder.metaURL(for: recording).path)[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) < liveWithin
    }

    @discardableResult
    public func deleteAll(phases: [UUID: TranscriptionPhase] = [:], live: Set<UUID> = []) async -> Int {
        var failed = 0
        for id in folder.recordings() where !live.contains(id) {
            do {
                try await delete(id, phase: phases[id], live: live)
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
        // A plain bookmark: Perekey is not sandboxed (no app-sandbox entitlement), so it needs no security scope.
        let reference = FileReference(path: url.path, bookmark: try? url.bookmarkData())
        let id = try folder.create(.file(reference), excludedFromBackup: excludedFromBackup)
        await queue.enqueue(TranscriptionJob(recording: id, model: model, diarize: diarize))
        return id
    }

    /// How much room recordings take on disk.
    public func diskUsage() -> Int64 { RecordingsDiskUsage.bytes(in: folder.root) }
}
