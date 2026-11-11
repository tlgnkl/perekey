// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
import os
import PerekeyCore

/// The folder of typing recordings: `Perekey/sessions.noindex` in
/// Application Support. Only a build with `PEREKEY_RECORD` has it
/// (CONTRIBUTING.md, «Recording typing for the measure»).
///
/// A recording holds typed text. The folder is the owner's only (0700), each
/// file too (0600). The folder and its files stay out of Time Machine, with
/// the mark `DictationHistoryFile` uses, and out of Spotlight (`.noindex`).
/// A file lives 30 days: older ones go at launch.
public struct SessionFolder: Sendable {
    /// How long a recording is kept, in seconds: 30 days, as plan 6.3 asks.
    public static let lifetime: TimeInterval = 30 * 24 * 3600

    public let directory: URL

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "sessions.noindex", directoryHint: .isDirectory)
    }

    public init(directory: URL = SessionFolder.defaultDirectory) {
        self.directory = directory
    }

    /// Creates the folder if needed, closed to the owner and out of the backup.
    public func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // A folder that existed keeps its old permissions without this.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        DictationHistoryFile.excludeFromBackup(directory)
    }

    /// The recordings, oldest name first.
    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".\(SessionRecorder.fileExtension)") }.sorted()
            .map { directory.appending(path: $0, directoryHint: .notDirectory) }
    }

    /// Creates the next file of `day` ("2026-11-10"): `2026-11-10-1.pksession`,
    /// `-2` for the next launch that day. 0600 from the first byte, out of the
    /// backup. Returns the file open for appending, with `first` written.
    func create(day: String, first: Data) throws -> (URL, FileHandle) {
        try prepare()
        let manager = FileManager.default
        var number = 1
        while true {
            let url = directory.appending(path: "\(day)-\(number).\(SessionRecorder.fileExtension)",
                                          directoryHint: .notDirectory)
            if manager.fileExists(atPath: url.path) {
                number += 1
                continue
            }
            guard manager.createFile(atPath: url.path, contents: first, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            DictationHistoryFile.excludeFromBackup(url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return (url, handle)
        }
    }

    /// Removes the recordings last written more than `lifetime` ago.
    /// Returns how many went.
    @discardableResult
    public func removeExpired(now: Date = Date()) -> Int {
        let cutoff = now.addingTimeInterval(-Self.lifetime)
        var removed = 0
        for url in files() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff, (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes every recording.
    public func eraseAll() {
        for url in files() { try? FileManager.default.removeItem(at: url) }
    }
}

/// The disk's half of the typing recorder: takes batches of `RecordingBuffer`
/// entries, makes session lines of them (`SessionLine`, docs/classifier.md,
/// «Замер на живых сессиях») and appends them to the file of the day, on a
/// serial queue of its own at utility QoS. Nothing here runs on the tap thread.
///
/// A file starts with its header and a snapshot. Steps and gaps that come
/// while no file is open (after erasing, or when it could not be created or
/// written) are dropped: the buffer starts a new segment, and its snapshot
/// starts the file. A new file starts at each launch, and on the first quiet
/// point of a new day. A batch that could not be written is answered with
/// `failed`, so that the buffer (and the badge in the menu bar) know.
///
/// A file lives 30 days (`SessionFolder.lifetime`): the old ones go at launch
/// and again when the day changes while the app runs.
///
/// Nothing typed goes to the log: it gets counts and error codes only.
///
/// `@unchecked Sendable`: the state below is touched only on `queue`.
public final class SessionRecorder: @unchecked Sendable {
    /// The file name extension, as `SessionFile` of `perekey-eval replay` reads it.
    public static let fileExtension = "pksession"
    /// The label of the recorder's queue, and the marker of a build that has
    /// the recorder: `scripts/check-no-recorder.sh` fails on a binary with it.
    public static let marker = "app.perekey.session-recorder"

    public let folder: SessionFolder
    private let queue = DispatchQueue(label: SessionRecorder.marker, qos: .utility)
    private let header: @Sendable (Date) -> SessionHeader
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let log = Logger(subsystem: "app.perekey", category: "recorder")
    private let encoder: JSONEncoder

    // On `queue`
    private var handle: FileHandle?
    private var day: String?
    /// The day the folder was last swept of old files.
    private var sweptDay: String?
    /// The batch being written could not be created or written to a file.
    private var failed = false
    /// The files were erased and the buffer has not started over yet
    /// (`resume`). The generation of the recording: batches that reach the queue
    /// in this stretch were made before the buffer heard of the erasing, and
    /// are dropped; read and set on `queue` only, so the tap thread reads nothing.
    private var erased = false

    /// The recorder's answer about a batch.
    public struct Written: Sendable {
        /// The array of the batch, empty and with its room: for the buffer to reuse.
        public var batch: [RecordingBuffer.Entry]
        /// How many entries it held.
        public var count: Int
        /// The day of the file is over.
        public var newDay: Bool
        /// A file could not be created, or writing to it failed.
        public var failed: Bool
    }

    /// - Parameters:
    ///   - perekey: the version of Perekey, for the header.
    ///   - build: its build number.
    ///   - now: the clock; tests move it to a new day.
    public init(folder: SessionFolder = SessionFolder(), perekey: String, build: String,
                calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() })
    {
        self.folder = folder
        header = { SessionHeader(perekey: perekey, build: build, time: $0.timeIntervalSince1970) }
        self.now = now
        self.calendar = calendar
        // As SessionFile of PerekeyModelKit writes and reads: sorted keys,
        // infinities as strings.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                       negativeInfinity: "-inf", nan: "nan")
        self.encoder = encoder
    }

    /// Writes a batch on the recorder's queue, then calls `done` there with
    /// the answer (`Written`). `close`: the recording stops; the file is closed
    /// after the batch.
    ///
    /// The one hop to the queue per batch is all the tap thread pays here: a
    /// closure the size of a few pointers, once for 256 entries or a second.
    public func write(_ batch: [RecordingBuffer.Entry], close: Bool = false,
                      done: @escaping @Sendable (Written) -> Void)
    {
        queue.async { [self] in
            done(perform(batch, close: close))
        }
    }

    /// Writes the last batch and closes the file before it returns: for the
    /// quit of the app, which must not leave the batch to a queue that dies
    /// with the process. Never on the tap thread's hot path.
    @discardableResult
    public func finish(_ batch: [RecordingBuffer.Entry]) -> Written {
        queue.sync { perform(batch, close: true) }
    }

    private func perform(_ batch: [RecordingBuffer.Entry], close: Bool) -> Written {
        failed = false
        // Typed before the buffer heard of the erasing: not for a file.
        if !erased { append(batch) }
        if close { closeFile() }
        let today = dayName(now())
        let newDay = day.map { $0 != today } ?? false
        sweepIfNewDay(today)
        // The array goes back for reuse, emptied here: the snapshots in it
        // are released on this queue, not on the tap thread.
        var used = batch
        used.removeAll(keepingCapacity: true)
        return Written(batch: used, count: batch.count, newDay: newDay, failed: failed)
    }

    /// Closes the file and removes every recording, after the batches
    /// handed over before. Batches handed over after it, until `resume()`,
    /// are dropped: they hold what was typed before the buffer heard of the
    /// erasing, and a snapshot among them would open a file again. `then`
    /// runs on the queue; the buffer must start over
    /// (`RecordingBuffer.restart`) and then call `resume()`.
    public func eraseAll(then: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            closeFile()
            folder.eraseAll()
            erased = true
            then()
        }
    }

    /// The buffer started over after `eraseAll`: its batches are written
    /// again. Called on the tap thread after `restart()`, so every batch
    /// queued before it is ahead of this in the queue and dropped.
    public func resume() {
        queue.async { [self] in erased = false }
    }

    /// Removes the recordings older than `SessionFolder.lifetime`. The
    /// recorder does it again by itself when the day changes.
    public func removeExpired() {
        queue.async { [self] in sweep(dayName(now())) }
    }

    private func sweepIfNewDay(_ today: String) {
        if sweptDay != today { sweep(today) }
    }

    private func sweep(_ today: String) {
        sweptDay = today
        let removed = folder.removeExpired(now: now())
        if removed > 0 { log.info("Removed \(removed, privacy: .public) old recordings") }
    }

    /// Waits for the batches handed over so far (tests).
    func drain() {
        queue.sync {}
    }

    private func append(_ batch: [RecordingBuffer.Entry]) {
        var data = Data()
        for entry in batch {
            let line: SessionLine
            switch entry {
            case let .snapshot(machine, classifier, newFile):
                if newFile || handle == nil {
                    flush(&data)
                    closeFile()
                    openFile()
                }
                line = .snapshot(SessionSnapshot(machine: machine, classifier: classifier.map(ClassifierSpec.init)))
            case let .step(event, output):
                guard let recorded = RecordedEvent(event) else { continue }
                line = .step(SessionStep(event: recorded, output: OutputDigest(output)))
            case let .gap(reason):
                line = .gap(reason)
            }
            // Outside a file (erased, or it could not be opened: `failed`) the lines go nowhere.
            guard handle != nil else { continue }
            do {
                data.append(try encoder.encode(line))
                data.append(0x0A)
            } catch {
                log.error("A session line could not be encoded: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        flush(&data)
    }

    private func flush(_ data: inout Data) {
        guard !data.isEmpty, let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            log.error("Writing the recording failed: \((error as NSError).code, privacy: .public); it stops until the next file")
            failed = true
            closeFile()
        }
        data.removeAll(keepingCapacity: true)
    }

    private func openFile() {
        let started = now()
        let name = dayName(started)
        do {
            var first = try encoder.encode(SessionLine.header(header(started)))
            first.append(0x0A)
            let (_, opened) = try folder.create(day: name, first: first)
            handle = opened
            day = name
        } catch {
            log.error("A recording file could not be created: \((error as NSError).code, privacy: .public)")
            failed = true
        }
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        day = nil
    }

    private func dayName(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
#endif
