// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import os
import PerekeyCore
import PerekeyVoiceCore

/// Where speech models live on disk.
public struct VoiceModelLocations: Sendable, Equatable {
    /// The user's models: `<id>/` when ready, `<id>.partial/` while downloading.
    public var models: URL
    /// Models an administrator put there, used instead of downloads when a
    /// profile sets `VoiceModelDownloadsDisabled`.
    public var managed: URL
    /// The CoreML compilation cache of this process. CoreML keys it by
    /// content hashes, not by model, so only "Delete All" clears it.
    public var coreMLCache: URL

    public init(models: URL, managed: URL, coreMLCache: URL) {
        self.models = models
        self.managed = managed
        self.coreMLCache = coreMLCache
    }

    /// `PEREKEY_VOICE_MODELS` moves the user's models elsewhere, for tests by
    /// hand. CoreML caches compiled models in `~/Library/Caches/<bundle id>`,
    /// or the process name for a tool without a bundle.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cacheName: String = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    ) -> VoiceModelLocations {
        let models = environment["PEREKEY_VOICE_MODELS"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.applicationSupportDirectory.appending(path: "Perekey/VoiceModels", directoryHint: .isDirectory)
        return VoiceModelLocations(
            models: models,
            managed: URL(filePath: "/Library/Application Support/Perekey/VoiceModels", directoryHint: .isDirectory),
            coreMLCache: URL.cachesDirectory
                .appending(path: cacheName, directoryHint: .isDirectory)
                .appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory))
    }
}

public enum VoiceModelState: Sendable, Equatable {
    case absent
    /// A stopped download; the next one resumes from `received` bytes.
    case partial(received: Int64)
    case downloading(received: Int64)
    /// A download waits for a network and goes on by itself when one comes.
    case waitingForNetwork(received: Int64)
    case ready
    /// Files are missing or have the wrong size or checksum; download again.
    case damaged
}

public enum VoiceModelFailure: Error, Equatable, Sendable {
    case voiceDisabled
    case downloadsDisabled
    /// `VoiceHTTP` does not allow model downloads.
    case networkBlocked
    case unknownModel(String)
    case notReady(String)
    /// An engine holds the model.
    case inUse(String)
    /// Silero VAD stays while this recognizer is on disk or downloading.
    case requiredBy(String)
    case http(status: Int, host: String)
    /// A redirect led away from Hugging Face; it was not followed.
    case untrustedRedirect(host: String)
    case checksumMismatch(String)
    case network(String)
    /// No network for two waits of `VoiceHTTP` in a row.
    case offline
    /// The volume has `available` bytes, the download needs `needed`.
    case notEnoughSpace(needed: Int64, available: Int64)
    case disk(String)

    init(_ failure: VoiceHTTP.Failure) {
        switch failure {
        case .blocked: self = .networkBlocked
        case .redirectRefused(let host): self = .untrustedRedirect(host: host)
        case .offline: self = .offline
        }
    }
}

/// One model as the Voice settings show it.
public struct VoiceModelStatus: Sendable, Equatable, Identifiable {
    public let entry: VoiceModelEntry
    public var state: VoiceModelState
    /// An engine holds it: "Delete" refuses.
    public var isInUse: Bool
    /// From the administrator's folder: no "Download" and no "Delete".
    public var isManaged: Bool
    /// Why the last download or check failed.
    public var failure: VoiceModelFailure?
    /// Bytes "Download" brings: a recognizer counts Silero VAD while VAD is not there.
    public var size: Int64

    public init(entry: VoiceModelEntry, state: VoiceModelState, isInUse: Bool = false, isManaged: Bool = false,
                failure: VoiceModelFailure? = nil, size: Int64? = nil)
    {
        self.entry = entry
        self.state = state
        self.isInUse = isInUse
        self.isManaged = isManaged
        self.failure = failure
        self.size = size ?? entry.totalSize
    }

    public var id: String { entry.id }
    /// The repository page at the pinned commit of each part.
    public var addresses: [String] { entry.sources.map(\.pageURL) }

    /// 0...1 of the model's own files while downloading or stopped halfway.
    public var progress: Double? {
        switch state {
        case .downloading(let received), .waitingForNetwork(let received), .partial(let received):
            entry.totalSize > 0 ? min(1, Double(received) / Double(entry.totalSize)) : 0
        default: nil
        }
    }
}

public struct VoiceModelDiskUsage: Sendable, Equatable {
    /// The user's models folder, partial downloads included.
    public var models: Int64
    /// The CoreML compilation cache.
    public var cache: Int64
    public init(models: Int64, cache: Int64) {
        self.models = models
        self.cache = cache
    }

    public var total: Int64 { models + cache }
}

/// Speech model files: the catalog against the disk, downloads, deletion.
///
/// Only this store downloads models, only through `VoiceHTTP`; the loaders of
/// FluidAudio and WhisperKit are never called. A download goes into
/// `<id>.partial/`: each file into `<file>.part` next to its place, resumed
/// with `Range`, checked against its SHA-256 and renamed into place. When
/// every file is there, `<id>.partial/` is renamed to `<id>/`, so a
/// half-downloaded model is never "ready". At launch "ready" means every file
/// is there with its size; checksums are not computed again.
///
/// A download belongs to the store, not to the caller: it runs until it ends,
/// fails or `cancelDownload` stops it.
///
/// Engines `acquire` a model before loading it and `release` it after; a held
/// model cannot be deleted or repaired.
public actor VoiceModelStore {
    public nonisolated let catalog: [VoiceModelEntry]
    public nonisolated let locations: VoiceModelLocations
    public nonisolated let managed: ManagedSettings
    private let http: VoiceHTTP
    private let host: String
    private let limits: Limits

    private var states: [String: VoiceModelState] = [:]
    private var failures: [String: VoiceModelFailure] = [:]
    private var holders: [String: Int] = [:]
    /// Administrator's models whose checksums passed in this process.
    private var verified: Set<String> = []
    private var verifying: [String: Task<Void, Error>] = [:]
    /// By the model asked for; a recognizer's brings Silero VAD first.
    private var downloads: [String: Task<Void, Error>] = [:]
    /// By the model whose files are coming.
    private var fetches: [String: Task<Void, Error>] = [:]
    /// Downloads waiting for each fetch.
    private var fetchUsers: [String: Int] = [:]
    /// The latest fetch of each model and the last report of it taken:
    /// reports hop to the actor in no set order, older ones are dropped.
    private var reports: [String: (generation: Int, sequence: Int)] = [:]
    private var cacheClearPending = false
    private var observers: [UUID: AsyncStream<[VoiceModelStatus]>.Continuation] = [:]

    private static let log = Logger(subsystem: "app.perekey", category: "voice-models")
    /// Names the catalog commits a folder was downloaded from.
    static let manifestName = ".perekey-model"

    struct Limits: Sendable {
        /// Failed requests in a row before a download gives up; a request
        /// that brought the file further resets the count.
        var networkAttempts = 6
        /// Downloads of one file whose checksum did not match.
        var checksumAttempts = 3
        /// Expired CDN links in a row.
        var expiredLinks = 4
        /// 206 answers for other bytes than asked, in a row, before a file
        /// starts over from its first byte.
        var foreignRanges = 3
        /// Requests in a row that found no network for the whole wait.
        var offlineAttempts = 2
        var retryDelay: @Sendable (Int) -> Duration = { .seconds(min(30, 1 << min($0, 5))) }
        /// Free bytes on the volume of a folder; nil when unknown.
        var freeSpace: @Sendable (URL) -> Int64? = { folder in
            (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        /// Writes a chunk of a `.part` file.
        var write: @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    }

    public init(locations: VoiceModelLocations = .standard(), managed: ManagedSettings, http: VoiceHTTP = .shared) {
        self.init(
            catalog: ModelCatalog.all, locations: locations, managed: managed, http: http, host: ModelCatalog.host,
            limits: Limits())
    }

    init(
        catalog: [VoiceModelEntry], locations: VoiceModelLocations, managed: ManagedSettings, http: VoiceHTTP,
        host: String, limits: Limits
    ) {
        self.catalog = catalog
        self.locations = locations
        self.managed = managed
        self.http = http
        self.host = host
        self.limits = limits
        Self.removeTrash(in: locations.models)
        let scan = Self.scan(catalog: catalog, locations: locations, managed: managed)
        states = scan
    }

    // MARK: - State

    /// Downloads are possible: voice is on and no profile forbids them.
    public nonisolated var canDownload: Bool { !managed.voiceDisabled && !managed.voiceModelDownloadsDisabled }

    public var statuses: [VoiceModelStatus] { catalog.map(status) }

    public func status(of id: String) -> VoiceModelStatus? { entry(id).map(status) }

    /// The statuses now and after every change. Progress comes at most every
    /// 256 KB of a file.
    public func updates() -> AsyncStream<[VoiceModelStatus]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [VoiceModelStatus].self, bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        observers[key] = continuation
        continuation.yield(statuses)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(key) }
        }
        return stream
    }

    /// Reads the disk again, for files changed behind the app's back.
    public func refresh() {
        Self.removeTrash(in: locations.models)
        let scan = Self.scan(catalog: catalog, locations: locations, managed: managed)
        for (id, state) in scan where fetches[id] == nil {
            states[id] = state
        }
        verified = verified.filter { states[$0] == .ready }
        publish()
    }

    /// The folder of a ready model, without holding it.
    public func folder(of id: String) -> URL? {
        states[id] == .ready ? modelFolder(id) : nil
    }

    // MARK: - Engines

    /// Holds a ready model for an engine and returns its folder. A recognizer
    /// needs Silero VAD ready too. Models from the administrator's folder are
    /// checked against their SHA-256 on the first hold in a process.
    public func acquire(_ id: String) async throws -> URL {
        guard !managed.voiceDisabled else { throw VoiceModelFailure.voiceDisabled }
        guard let entry = entry(id) else { throw VoiceModelFailure.unknownModel(id) }
        guard states[id] == .ready else { throw VoiceModelFailure.notReady(id) }
        if entry.engine.recognizes, let vad, states[vad.id] != .ready { throw VoiceModelFailure.notReady(vad.id) }
        holders[id, default: 0] += 1
        publish()
        if managed.voiceModelDownloadsDisabled, !verified.contains(id) {
            do {
                try await verifyManaged(id)
            } catch {
                release(id)
                throw error
            }
        }
        return modelFolder(id)
    }

    public func release(_ id: String) {
        guard let count = holders[id], count > 0 else { return }
        holders[id] = count == 1 ? nil : count - 1
        if holders.isEmpty, cacheClearPending {
            clearCoreMLCache()
        }
        publish()
    }

    private func verifyManaged(_ id: String) async throws {
        if let running = verifying[id] { return try await running.value }
        guard let entry = entry(id) else { return }
        let folder = modelFolder(id)
        let task = Task.detached { try Self.verifyChecksums(of: entry, in: folder) }
        verifying[id] = task
        defer { verifying[id] = nil }
        do {
            try await task.value
            verified.insert(id)
        } catch let failure as VoiceModelFailure {
            states[id] = .damaged
            failures[id] = failure
            publish()
            throw failure
        }
    }

    // MARK: - Download

    /// Starts a download, or joins the running one, and waits for it. A
    /// recognizer brings Silero VAD along when it is not there yet. The
    /// download belongs to the store: cancelling the caller ends the wait
    /// with `CancellationError` and leaves the download running. Only
    /// `cancelDownload` stops it. Repairing a damaged model an engine holds
    /// is refused with `inUse`.
    public func download(_ id: String) async throws {
        guard !managed.voiceDisabled else { throw VoiceModelFailure.voiceDisabled }
        guard !managed.voiceModelDownloadsDisabled else { throw VoiceModelFailure.downloadsDisabled }
        guard let entry = entry(id) else { throw VoiceModelFailure.unknownModel(id) }
        // A stopped download finishes before a new one starts on its files.
        while let running = downloads[id], running.isCancelled {
            _ = await running.result
        }
        if let running = downloads[id] { return try await Self.wait(for: running) }

        // A recognizer is ready only with Silero VAD: a VAD from an older
        // catalog is repaired by downloading the recognizer.
        let chain = ((entry.engine.recognizes ? vad.map { [$0] } : nil) ?? []) + [entry]
        let missing = chain.filter { states[$0.id] != .ready }
        guard !missing.isEmpty else { return }
        // A repair moves the files of the model aside.
        for part in missing {
            if holders[part.id] != nil { throw VoiceModelFailure.inUse(part.id) }
            if part.engine == .fluidAudioVad, let holder = heldRecognizer { throw VoiceModelFailure.inUse(holder) }
        }
        let task = Task { try await self.run(missing, for: id) }
        downloads[id] = task
        try await Self.wait(for: task)
    }

    /// Stops a download; the files that arrived stay for the next one.
    public func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
        fetches[id]?.cancel()
    }

    private func run(_ chain: [VoiceModelEntry], for id: String) async throws {
        defer { downloads[id] = nil }
        for entry in chain where states[entry.id] != .ready {
            try Task.checkCancellation()
            let fetch = await fetchTask(entry)
            // Silero VAD may come for several recognizers at once: a stopped
            // one leaves it to the others.
            fetchUsers[entry.id, default: 0] += 1
            do {
                try await Self.wait(for: fetch)
            } catch {
                // A fetch this download stopped ends first: its files and
                // state settle before the caller hears of the stop.
                if leave(fetch, of: entry.id) { _ = await fetch.result }
                throw error
            }
            leave(fetch, of: entry.id)
        }
    }

    /// The last download waiting for a fetch stops it, unless it has ended.
    /// True when it was the last.
    @discardableResult
    private func leave(_ fetch: Task<Void, Error>, of id: String) -> Bool {
        let left = (fetchUsers[id] ?? 1) - 1
        fetchUsers[id] = left > 0 ? left : nil
        guard left <= 0 else { return false }
        fetch.cancel()
        return true
    }

    /// The running fetch of `entry`, or a new one once a stopped one has ended.
    private func fetchTask(_ entry: VoiceModelEntry) async -> Task<Void, Error> {
        while let running = fetches[entry.id] {
            if !running.isCancelled { return running }
            _ = await running.result
        }
        let task = Task { try await self.fetch(entry) }
        fetches[entry.id] = task
        return task
    }

    private func fetch(_ entry: VoiceModelEntry) async throws {
        let id = entry.id
        defer { fetches[id] = nil }
        failures[id] = nil
        do {
            try checkSpace(for: entry)
            let partial = try preparePartial(entry)
            let files = entry.sources.flatMap { source in source.files.map { (source, $0) } }
            var before: Int64 = 0
            let generation = (reports[id]?.generation ?? 0) + 1
            reports[id] = (generation, 0)
            let sequence = OSAllocatedUnfairLock(initialState: 0)
            states[id] = .downloading(received: Self.receivedBytes(of: files.map(\.1), in: partial))
            publish()
            for (index, (source, file)) in files.enumerated() {
                try Task.checkCancellation()
                // Files before this one are in place, files after it may have arrived in part.
                let start = before
                let after = Self.receivedBytes(of: files[(index + 1)...].map(\.1), in: partial)
                try await Self.downloadFile(
                    file, of: source, into: partial, http: http, host: host, limits: limits,
                    progress: { [weak self] received in
                        let number = sequence.withLock { $0 += 1; return $0 }
                        Task { await self?.report(id, generation, number, .progress(start + received + after)) }
                    },
                    waiting: { [weak self] waiting in
                        let number = sequence.withLock { $0 += 1; return $0 }
                        Task { await self?.report(id, generation, number, .waiting(waiting)) }
                    })
                before += file.size
                states[id] = .downloading(received: before + after)
                publish()
            }
            try Task.checkCancellation()
            // No suspension from here to the rename: a delete waits for this
            // task, so it cannot remove the folder halfway.
            try Self.finish(entry, partial: partial, into: modelFolder(id), trash: trashFolder(id))
            states[id] = .ready
            Self.log.info("model \(id, privacy: .public) is ready")
        } catch {
            states[id] = Self.scan(entry, locations: locations, managed: managed)
            if !(error is CancellationError) && !Task.isCancelled {
                let failure = (error as? VoiceModelFailure) ?? .disk(String(describing: error))
                failures[id] = failure
                Self.log.error("model \(id, privacy: .public): \(String(describing: failure), privacy: .public)")
            }
            publish()
            throw Task.isCancelled ? CancellationError() : error
        }
        publish()
    }

    private enum Report {
        case progress(Int64)
        case waiting(Bool)
    }

    /// Takes a report of the latest fetch that is newer than the last one taken.
    private func report(_ id: String, _ generation: Int, _ number: Int, _ report: Report) {
        guard let last = reports[id], last.generation == generation, number > last.sequence else { return }
        reports[id] = (generation, number)
        switch report {
        case .progress(let received): progress(id, received)
        case .waiting(let waiting): self.waiting(id, waiting)
        }
    }

    /// `received` only grows: a file started over does not move the bar back.
    private func progress(_ id: String, _ received: Int64) {
        switch states[id] {
        case .downloading(let now) where received > now, .waitingForNetwork(let now) where received > now:
            states[id] = .downloading(received: received)
            publish()
        default:
            return
        }
    }

    private func waiting(_ id: String, _ waiting: Bool) {
        switch (states[id], waiting) {
        case (.downloading(let received), true):
            states[id] = .waitingForNetwork(received: received)
        case (.waitingForNetwork(let received), false):
            states[id] = .downloading(received: received)
        default:
            return
        }
        publish()
    }

    /// Refuses a download the volume has no room for, before any request.
    private func checkSpace(for entry: VoiceModelEntry) throws {
        let manager = FileManager.default
        let partial = partialFolder(entry.id)
        let have = Self.receivedBytes(
            of: entry, in: manager.fileExists(atPath: partial.path) ? partial : modelFolder(entry.id))
        let needed = entry.totalSize - have
        try? manager.createDirectory(at: locations.models, withIntermediateDirectories: true)
        if let available = limits.freeSpace(locations.models), available < needed {
            throw VoiceModelFailure.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// `<id>.partial/` for this catalog version: a damaged ready folder is
    /// turned back into one, files renamed to `.part` so each is checked
    /// again; one left by another version is cleared.
    private func preparePartial(_ entry: VoiceModelEntry) throws -> URL {
        let manager = FileManager.default
        let partial = partialFolder(entry.id)
        let ready = modelFolder(entry.id)
        let manifest = Self.manifest(of: entry)
        do {
            try manager.createDirectory(at: locations.models, withIntermediateDirectories: true)
            if manager.fileExists(atPath: ready.path) {
                if manager.fileExists(atPath: partial.path) {
                    try manager.removeItem(at: ready)
                } else {
                    try Self.rename(ready, to: partial)
                    try Self.markUnchecked(partial)
                }
            }
            let manifestURL = partial.appending(path: Self.manifestName)
            if let existing = try? String(contentsOf: manifestURL, encoding: .utf8), existing != manifest {
                try manager.removeItem(at: partial)
            }
            try manager.createDirectory(at: partial, withIntermediateDirectories: true)
            try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        } catch {
            throw VoiceModelFailure.disk(String(describing: error))
        }
        return partial
    }

    /// Waits for `task` without owning it: cancelling the caller ends the
    /// wait, not the task.
    private static func wait(for task: Task<Void, Error>) async throws {
        let waiter = Waiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
                Task { waiter.finish(await task.result) }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    // MARK: - Delete

    /// Deletes a model. Refuses while an engine holds it, and Silero VAD
    /// while a recognizer needs it; stops its download first. The CoreML
    /// cache stays: it is shared by every model, and a model compiled again
    /// costs minutes. The administrator's folder is never touched.
    public func delete(_ id: String) async throws {
        guard let entry = entry(id) else { throw VoiceModelFailure.unknownModel(id) }
        try checkDeletable(entry)
        // A download started while the last one stopped is stopped too.
        while downloads[id] != nil || fetches[id] != nil {
            await stopDownload(id)
            try checkDeletable(entry)
        }
        try removeUserCopy(id)
        publish()
    }

    /// Deletes every model no engine holds, what older catalogs left and the
    /// CoreML cache, once no engine holds a model. Returns the ids it kept
    /// because they are in use: held models, and Silero VAD with a held
    /// recognizer.
    @discardableResult
    public func deleteAll() async throws -> [String] {
        while !downloads.isEmpty || !fetches.isEmpty {
            for id in Set(downloads.keys).union(fetches.keys) {
                await stopDownload(id)
            }
        }
        let recognizerHeld = heldRecognizer != nil
        let kept = catalog.filter { holders[$0.id] != nil || ($0.engine == .fluidAudioVad && recognizerHeld) }.map(\.id)
        for entry in catalog where !kept.contains(entry.id) {
            try removeUserCopy(entry.id)
        }
        try removeLeftovers(keeping: Set(kept))
        clearCoreMLCache()
        publish()
        return kept
    }

    private func checkDeletable(_ entry: VoiceModelEntry) throws {
        guard holders[entry.id] == nil else { throw VoiceModelFailure.inUse(entry.id) }
        guard entry.engine == .fluidAudioVad else { return }
        let user = catalog.first { recognizer in
            let id = recognizer.id
            guard recognizer.engine.recognizes else { return false }
            return holders[id] != nil || downloads[id] != nil || fetches[id] != nil
                || states[id] == .ready || states[id] == .damaged
        }
        if let user { throw VoiceModelFailure.requiredBy(user.id) }
    }

    private func stopDownload(_ id: String) async {
        let running = [downloads[id], fetches[id]].compactMap { $0 }
        for task in running { task.cancel() }
        for task in running { _ = await task.result }
    }

    private func removeUserCopy(_ id: String) throws {
        let manager = FileManager.default
        do {
            for folder in [modelFolder(id, userCopy: true), partialFolder(id)] where manager.fileExists(atPath: folder.path) {
                try manager.removeItem(at: folder)
            }
        } catch {
            throw VoiceModelFailure.disk(String(describing: error))
        }
        failures[id] = nil
        verified.remove(id)
        states[id] = Self.scan(entry(id)!, locations: locations, managed: managed)
    }

    /// Folders of models no longer in the catalog and interrupted swaps. Only
    /// what this store makes: a folder with its manifest, `.partial` or `.trash-`.
    private func removeLeftovers(keeping: Set<String>) throws {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: locations.models.path) else { return }
        let known = Set(catalog.map(\.id))
        for name in names {
            let id = name.components(separatedBy: ".").first ?? name
            guard !keeping.contains(id), !known.contains(name) else { continue }
            let url = locations.models.appending(path: name, directoryHint: .isDirectory)
            let ours = name.hasSuffix(".partial") || name.contains(".trash-")
                || manager.fileExists(atPath: url.appending(path: Self.manifestName).path)
            if ours {
                do {
                    try manager.removeItem(at: url)
                } catch {
                    throw VoiceModelFailure.disk(String(describing: error))
                }
            }
        }
    }

    /// Clears the CoreML cache, or marks it to clear once no engine holds a
    /// model: a loaded model may still read its compiled form.
    private func clearCoreMLCache() {
        guard holders.isEmpty else {
            cacheClearPending = true
            return
        }
        cacheClearPending = false
        try? FileManager.default.removeItem(at: locations.coreMLCache)
    }

    // MARK: - Disk

    /// Bytes on disk: the user's models with partial downloads, and the CoreML cache.
    public nonisolated func diskUsage() async -> VoiceModelDiskUsage {
        VoiceModelDiskUsage(
            models: Self.allocatedSize(of: locations.models), cache: Self.allocatedSize(of: locations.coreMLCache))
    }

    // MARK: - Helpers

    private func entry(_ id: String) -> VoiceModelEntry? { catalog.first { $0.id == id } }

    private var vad: VoiceModelEntry? { catalog.first { $0.engine == .fluidAudioVad } }

    /// A recognizer an engine holds: its VAD is in use too.
    private var heldRecognizer: String? {
        catalog.first { $0.engine.recognizes && holders[$0.id] != nil }?.id
    }

    private func status(_ entry: VoiceModelEntry) -> VoiceModelStatus {
        var size = entry.totalSize
        if entry.engine.recognizes, let vad, states[vad.id] != .ready {
            size += vad.totalSize
        }
        return VoiceModelStatus(
            entry: entry, state: states[entry.id] ?? .absent, isInUse: holders[entry.id] != nil,
            isManaged: managed.voiceModelDownloadsDisabled, failure: failures[entry.id], size: size)
    }

    private func publish() {
        guard !observers.isEmpty else { return }
        let now = statuses
        for observer in observers.values { observer.yield(now) }
    }

    private func removeObserver(_ key: UUID) { observers[key] = nil }

    /// The folder engines load from: the administrator's under
    /// `VoiceModelDownloadsDisabled`, the user's otherwise.
    private func modelFolder(_ id: String, userCopy: Bool = false) -> URL {
        Self.modelFolder(id, locations: locations, managed: userCopy ? ManagedSettings() : managed)
    }

    private func partialFolder(_ id: String) -> URL {
        locations.models.appending(path: "\(id).partial", directoryHint: .isDirectory)
    }

    private func trashFolder(_ id: String) -> URL {
        locations.models.appending(path: "\(id).trash-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func modelFolder(_ id: String, locations: VoiceModelLocations, managed: ManagedSettings) -> URL {
        (managed.voiceModelDownloadsDisabled ? locations.managed : locations.models)
            .appending(path: id, directoryHint: .isDirectory)
    }

    static func manifest(of entry: VoiceModelEntry) -> String {
        entry.sources.map { "\($0.repo)@\($0.commit)\n" }.joined()
    }
}

/// One wait for a download: ends with the download, or earlier when the
/// waiting task is cancelled, whichever comes first.
private final class Waiter: Sendable {
    private let state = OSAllocatedUnfairLock<(
        continuation: CheckedContinuation<Void, Error>?, result: Result<Void, Error>?
    )>(initialState: (nil, nil))

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        let result = state.withLock { state -> Result<Void, Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

// MARK: - Files

extension VoiceModelStore {
    static func scan(
        catalog: [VoiceModelEntry], locations: VoiceModelLocations, managed: ManagedSettings
    ) -> [String: VoiceModelState] {
        Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, scan($0, locations: locations, managed: managed)) })
    }

    /// The state on disk, from sizes alone.
    static func scan(_ entry: VoiceModelEntry, locations: VoiceModelLocations, managed: ManagedSettings) -> VoiceModelState {
        let manager = FileManager.default
        let folder = modelFolder(entry.id, locations: locations, managed: managed)
        if manager.fileExists(atPath: folder.path) {
            if !managed.voiceModelDownloadsDisabled {
                let written = try? String(contentsOf: folder.appending(path: manifestName), encoding: .utf8)
                guard written == manifest(of: entry) else { return .damaged }
            }
            let complete = entry.sources.allSatisfy { source in
                source.files.allSatisfy { size(of: folder.appending(path: $0.path)) == $0.size }
            }
            return complete ? .ready : .damaged
        }
        if managed.voiceModelDownloadsDisabled { return .absent }
        let partial = locations.models.appending(path: "\(entry.id).partial", directoryHint: .isDirectory)
        guard manager.fileExists(atPath: partial.path) else { return .absent }
        return .partial(received: receivedBytes(of: entry, in: partial))
    }

    /// Bytes of `entry` in a partial folder: whole files and `.part` files.
    static func receivedBytes(of entry: VoiceModelEntry, in partial: URL) -> Int64 {
        receivedBytes(of: entry.sources.flatMap(\.files), in: partial)
    }

    static func receivedBytes(of files: [VoiceModelFile], in partial: URL) -> Int64 {
        files.reduce(0) { total, file in
            let target = partial.appending(path: file.path)
            if size(of: target) == file.size { return total + file.size }
            return total + min(file.size, size(of: partURL(target)) ?? 0)
        }
    }

    /// Removes `<id>.trash-*` folders a crash left between the two renames of a repair.
    static func removeTrash(in models: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: models.path) else { return }
        for name in names where name.contains(".trash-") {
            try? manager.removeItem(at: models.appending(path: name, directoryHint: .isDirectory))
        }
    }

    static func partURL(_ target: URL) -> URL {
        target.deletingLastPathComponent().appending(path: target.lastPathComponent + ".part")
    }

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `rename(2)`: atomic on one volume, and every path here is on one.
    static func rename(_ from: URL, to: URL) throws {
        guard Darwin.rename(from.path, to.path) == 0 else {
            throw VoiceModelFailure.disk("rename \(from.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Renames every file of a folder to `.part`, so the next download checks
    /// each one before trusting it.
    static func markUnchecked(_ folder: URL) throws {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        else { return }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                url.lastPathComponent != manifestName, url.pathExtension != "part"
            else { continue }
            try rename(url, to: partURL(url))
        }
    }

    static func verifyChecksums(of entry: VoiceModelEntry, in folder: URL) throws {
        for source in entry.sources {
            for file in source.files {
                let url = folder.appending(path: file.path)
                guard (try? sha256(of: url)) == file.sha256 else {
                    throw VoiceModelFailure.checksumMismatch(file.path)
                }
            }
        }
    }

    /// Every file in place with its size: `<id>.partial/` becomes `<id>/`.
    /// A damaged folder in the way goes aside first and is removed after.
    static func finish(_ entry: VoiceModelEntry, partial: URL, into ready: URL, trash: URL) throws {
        for source in entry.sources {
            for file in source.files where size(of: partial.appending(path: file.path)) != file.size {
                throw VoiceModelFailure.disk("\(file.path) is missing")
            }
        }
        let manager = FileManager.default
        let replacing = manager.fileExists(atPath: ready.path)
        if replacing { try rename(ready, to: trash) }
        try rename(partial, to: ready)
        if replacing { try? manager.removeItem(at: trash) }
    }

    /// Downloads one file into place unless it is there: `<file>.part`
    /// resumed with `Range`, checked against its SHA-256, renamed. Runs off
    /// the actor. `progress` gets the bytes of this file so far, `waiting`
    /// whether the request waits for a network.
    @concurrent
    static func downloadFile(
        _ file: VoiceModelFile, of source: VoiceModelSource, into folder: URL, http: VoiceHTTP, host: String,
        limits: Limits, progress: @escaping @Sendable (Int64) -> Void,
        waiting: @escaping @Sendable (Bool) -> Void = { _ in }
    ) async throws {
        let manager = FileManager.default
        let target = folder.appending(path: file.path)
        // A file in its place was checked before it got there.
        if size(of: target) == file.size { return }
        let part = partURL(target)
        do {
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw VoiceModelFailure.disk(String(describing: error))
        }
        guard let origin = URL(string: source.url(for: file, host: host)) else {
            throw VoiceModelFailure.disk("bad address for \(file.path)")
        }
        let originHost = origin.host() ?? ""

        var networkFailures = 0
        var checksumFailures = 0
        var expiredLinks = 0
        var foreignRanges = 0
        var offlines = 0
        /// The furthest `.part` got; a request counts as progress only past
        /// it, so a server that breaks off at random points cannot loop forever.
        var furthest = size(of: part) ?? 0
        /// The SHA-256 state after the first `bytes` of `.part`, kept from
        /// the last request so a resume does not read them again.
        var known: (bytes: Int64, hasher: SHA256)?

        /// The SHA-256 of a `.part` of `bytes` bytes.
        func digestOfPart(_ bytes: Int64) throws -> String {
            if let known, known.bytes == bytes { return hex(known.hasher.finalize()) }
            return try sha256(of: part)
        }

        /// The `.part` goes; the file comes again from its first byte.
        func startOver() {
            try? manager.removeItem(at: part)
            known = nil
            furthest = 0
        }

        /// A finished `.part`: into place, or removed for another try.
        func settle(_ digest: String) throws -> Bool {
            if digest == file.sha256 {
                try rename(part, to: target)
                progress(file.size)
                return true
            }
            startOver()
            checksumFailures += 1
            log.error("\(file.path, privacy: .public): checksum mismatch, try \(checksumFailures)")
            if checksumFailures >= limits.checksumAttempts { throw VoiceModelFailure.checksumMismatch(file.path) }
            return false
        }

        /// `end` is where the `.part` ended after the request, 0 when nothing came.
        func failed(_ failure: VoiceModelFailure, end: Int64 = 0) async throws {
            let progressed = end > furthest
            furthest = max(furthest, end)
            networkFailures = progressed ? 1 : networkFailures + 1
            if networkFailures >= limits.networkAttempts { throw failure }
            try await Task.sleep(for: limits.retryDelay(networkFailures))
        }

        while true {
            try Task.checkCancellation()
            let offset = size(of: part) ?? 0
            if offset > file.size {
                startOver()
                continue
            }
            if offset == file.size {
                if try settle(try digestOfPart(offset)) { return }
                continue
            }

            let writer = PartWriter(
                url: part, offset: offset, size: file.size, prefix: known?.bytes == offset ? known?.hasher : nil,
                write: limits.write, progress: progress)
            var request = URLRequest(url: origin)
            // The bytes as stored: a compressed body has another length, and
            // its ranges would count compressed bytes.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            let response: HTTPURLResponse
            do {
                response = try await http.stream(
                    request, purpose: .modelDownload, accept: { writer.begin($0) }, waiting: waiting,
                    receive: { try writer.write($0) })
            } catch {
                try? writer.close()
                known = writer.hashed
                // An answer that was taken breaks a run of odd ones, even if it broke off.
                if writer.started {
                    foreignRanges = 0
                    offlines = 0
                }
                switch error {
                case is CancellationError:
                    throw CancellationError()
                case VoiceHTTP.Failure.offline:
                    // The network may have come back just as the wait ran
                    // out: one more request before giving up.
                    offlines += 1
                    if offlines >= limits.offlineAttempts { throw VoiceModelFailure.offline }
                case let failure as VoiceHTTP.Failure:
                    throw VoiceModelFailure(failure)
                case let failure as PartWriter.DiskFailure:
                    throw VoiceModelFailure.disk(failure.description)
                case let overflow as PartWriter.Overflow:
                    startOver()
                    try await failed(.network(overflow.description))
                default:
                    try await failed(.network(error.localizedDescription), end: writer.end)
                }
                continue
            }
            offlines = 0
            do {
                try writer.close()
            } catch {
                throw VoiceModelFailure.disk(String(describing: error))
            }
            known = writer.hashed

            let status = response.statusCode
            let responseHost = response.url?.host() ?? originHost
            let redirected = response.url != origin
            if case .disk(let reason) = writer.refusal { throw VoiceModelFailure.disk(reason) }
            switch status {
            case 200, 206:
                guard writer.started else {
                    // A 206 for other bytes than asked leaves the `.part`
                    // alone; only a server that keeps doing it starts the file over.
                    if writer.refusal == .range {
                        foreignRanges += 1
                        if foreignRanges >= limits.foreignRanges {
                            foreignRanges = 0
                            startOver()
                        }
                    }
                    try await failed(.http(status: status, host: responseHost))
                    continue
                }
                foreignRanges = 0
                if writer.end < file.size {
                    // The connection closed early without an error.
                    try await failed(.network("\(file.path): \(writer.end) of \(file.size) bytes"), end: writer.end)
                    continue
                }
                if try settle(try writer.digest() ?? digestOfPart(file.size)) { return }
            case 416:
                // Nothing past `offset`: the part may be whole already.
                guard let whole = try? digestOfPart(offset) else {
                    try await failed(.http(status: status, host: responseHost))
                    continue
                }
                if try settle(whole) { return }
            case 403 where redirected, 410 where redirected:
                // The signed CDN link expired: ask the origin for a fresh one.
                expiredLinks += 1
                log.info("\(file.path, privacy: .public): CDN link expired (\(status)), asking \(originHost, privacy: .public) again")
                if expiredLinks >= limits.expiredLinks { throw VoiceModelFailure.http(status: status, host: responseHost) }
            case 408, 429, 500...599:
                try await failed(.http(status: status, host: responseHost))
            default:
                throw VoiceModelFailure.http(status: status, host: responseHost)
            }
        }
    }
}

/// Writes a response body into a `.part` file and hashes it on the way.
/// Used from the `VoiceHTTP` queue between `begin` and the end of the
/// request, and from the download before and after, never at once.
final class PartWriter: @unchecked Sendable {
    /// The server sent more bytes than the file has.
    struct Overflow: Error, CustomStringConvertible {
        let description: String
    }

    /// Writing to the disk failed: no room, no permission. Not retried.
    struct DiskFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Why `begin` left a 200 or 206 unread.
    enum Refusal: Equatable {
        /// A 206 for other bytes than asked.
        case range
        /// Not the length the file or its rest has, or another total: a
        /// proxy's page, a cut answer, another file.
        case length
        /// The `.part` could not be opened.
        case disk(String)
    }

    let url: URL
    let size: Int64
    /// Where the bytes of this response start in the file.
    private(set) var offset: Int64
    private(set) var written: Int64 = 0
    private(set) var started = false
    private(set) var refusal: Refusal?
    private var handle: FileHandle?
    /// Nil after a resume whose prefix was not hashed in this download.
    private var hasher: SHA256?
    private let prefix: SHA256?
    private var reported: Int64 = 0
    private let writeData: @Sendable (FileHandle, Data) throws -> Void
    private let progress: @Sendable (Int64) -> Void

    /// `prefix` is the SHA-256 state after the first `offset` bytes, when known.
    init(
        url: URL, offset: Int64, size: Int64, prefix: SHA256?,
        write: @escaping @Sendable (FileHandle, Data) throws -> Void, progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.url = url
        self.offset = offset
        self.size = size
        self.prefix = prefix
        self.writeData = write
        self.progress = progress
    }

    /// The end of what is in the file.
    var end: Int64 { offset + written }

    /// The SHA-256 state and the bytes it covers, for the next request.
    var hashed: (bytes: Int64, hasher: SHA256)? {
        started ? hasher.map { (end, $0) } : prefix.map { (offset, $0) }
    }

    /// Takes a 200 with the whole file, or a 206 with exactly the rest from
    /// `offset`. Anything else is left unread and the `.part` untouched.
    func begin(_ response: HTTPURLResponse) -> Bool {
        let start: Int64
        switch response.statusCode {
        case 200:
            guard response.expectedContentLength == size else {
                refusal = .length
                return false
            }
            start = 0
        case 206:
            let range = Self.contentRange(response.value(forHTTPHeaderField: "Content-Range"))
            guard range?.first == offset else {
                refusal = .range
                return false
            }
            // Another total is another file, whatever the rest looks like.
            guard range?.total == size, response.expectedContentLength == size - offset else {
                refusal = .length
                return false
            }
            start = offset
        default:
            return false
        }
        do {
            if !FileManager.default.fileExists(atPath: url.path),
                !FileManager.default.createFile(atPath: url.path, contents: nil)
            {
                throw DiskFailure(description: "cannot create \(url.lastPathComponent)")
            }
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.truncate(atOffset: UInt64(start))
                try handle.seek(toOffset: UInt64(start))
            } catch {
                try? handle.close()
                throw error
            }
            self.handle = handle
        } catch {
            refusal = .disk("\(url.lastPathComponent): \(error)")
            return false
        }
        offset = start
        hasher = start == 0 ? SHA256() : prefix
        started = true
        return true
    }

    func write(_ data: Data) throws {
        guard let handle else { return }
        guard end + Int64(data.count) <= size else {
            throw Overflow(description: "\(url.lastPathComponent): more bytes than \(size)")
        }
        do {
            try writeData(handle, data)
        } catch {
            throw DiskFailure(description: "\(url.lastPathComponent): \(error)")
        }
        hasher?.update(data: data)
        written += Int64(data.count)
        if end - reported >= 256 << 10 || end == size {
            reported = end
            progress(end)
        }
    }

    /// Flushes to disk, so a file renamed into place after a crash holds its bytes.
    func close() throws {
        guard let handle else { return }
        self.handle = nil
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw DiskFailure(description: "\(url.lastPathComponent): \(error)")
        }
    }

    /// Nil when the prefix of a resumed file was not hashed here.
    func digest() -> String? { hasher.map { VoiceModelStore.hex($0.finalize()) } }

    /// The first byte and the total of `bytes <first>-<last>/<total>`;
    /// the total is nil when it is `*` or missing.
    static func contentRange(_ header: String?) -> (first: Int64, total: Int64?)? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard let range = parts.first, let first = range.split(separator: "-").first.flatMap({ Int64($0) })
        else { return nil }
        return (first, parts.count == 2 ? Int64(parts[1]) : nil)
    }
}
