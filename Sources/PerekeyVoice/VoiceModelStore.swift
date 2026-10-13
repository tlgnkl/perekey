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
    /// content hashes, not by model, so it is cleared as a whole.
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
    case ready
    /// Files are missing or have the wrong size or checksum; download again.
    case damaged
}

public enum VoiceModelFailure: Error, Equatable, Sendable {
    case voiceDisabled
    case downloadsDisabled
    case unknownModel(String)
    case notReady(String)
    /// An engine holds the model.
    case inUse(String)
    case http(status: Int, host: String)
    case checksumMismatch(String)
    case network(String)
    case disk(String)
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

    public var id: String { entry.id }
    /// Bytes to download, as "Download" shows it.
    public var size: Int64 { entry.totalSize }
    /// The repository page at the pinned commit of each part.
    public var addresses: [String] { entry.sources.map(\.pageURL) }

    /// 0...1 while downloading or stopped halfway.
    public var progress: Double? {
        switch state {
        case .downloading(let received), .partial(let received):
            size > 0 ? min(1, Double(received) / Double(size)) : 0
        default: nil
        }
    }
}

public struct VoiceModelDiskUsage: Sendable, Equatable {
    /// The user's models folder, partial downloads included.
    public var models: Int64
    /// The CoreML compilation cache.
    public var cache: Int64
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
/// Engines `acquire` a model before loading it and `release` it after; a held
/// model cannot be deleted.
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
    private var downloads: [String: Task<Void, Error>] = [:]
    private var fetches: [String: Task<Void, Error>] = [:]
    private var cacheClearPending = false
    private var observers: [UUID: AsyncStream<[VoiceModelStatus]>.Continuation] = [:]

    private static let log = Logger(subsystem: "app.perekey", category: "voice-models")
    /// Names the catalog commits a folder was downloaded from.
    static let manifestName = ".perekey-model"

    struct Limits: Sendable {
        /// Failed requests in a row before a download gives up; a request
        /// that brought bytes resets the count.
        var networkAttempts = 6
        /// Downloads of one file whose checksum did not match.
        var checksumAttempts = 3
        /// Expired CDN links in a row.
        var expiredLinks = 4
        var retryDelay: @Sendable (Int) -> Duration = { .seconds(min(30, 1 << min($0, 5))) }
    }

    public init(
        catalog: [VoiceModelEntry] = ModelCatalog.all,
        locations: VoiceModelLocations = .standard(),
        managed: ManagedSettings,
        http: VoiceHTTP = .shared,
        host: String = ModelCatalog.host
    ) {
        self.init(catalog: catalog, locations: locations, managed: managed, http: http, host: host, limits: Limits())
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

    /// Holds a ready model for an engine and returns its folder. Models from
    /// the administrator's folder are checked against their SHA-256 on the
    /// first hold in a process.
    public func acquire(_ id: String) async throws -> URL {
        guard !managed.voiceDisabled else { throw VoiceModelFailure.voiceDisabled }
        guard entry(id) != nil else { throw VoiceModelFailure.unknownModel(id) }
        guard states[id] == .ready else { throw VoiceModelFailure.notReady(id) }
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

    /// Downloads a model and waits for it; a second call for the same model
    /// waits for the first. A recognizer brings Silero VAD along when it is
    /// not there yet. Cancelling the calling task, or `cancelDownload`, stops
    /// the download and keeps what arrived for the next one.
    public func download(_ id: String) async throws {
        guard !managed.voiceDisabled else { throw VoiceModelFailure.voiceDisabled }
        guard !managed.voiceModelDownloadsDisabled else { throw VoiceModelFailure.downloadsDisabled }
        guard let entry = entry(id) else { throw VoiceModelFailure.unknownModel(id) }
        if let running = downloads[id] { return try await running.value }
        if states[id] == .ready { return }

        var chain = [entry]
        if entry.engine.recognizes, let vad = catalog.first(where: { $0.engine == .fluidAudioVad }),
            states[vad.id] != .ready
        {
            chain.insert(vad, at: 0)
        }
        let task = Task { try await self.run(chain) }
        downloads[id] = task
        defer { downloads[id] = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops a download; the files that arrived stay for the next one.
    public func cancelDownload(_ id: String) {
        downloads[id]?.cancel()
        fetches[id]?.cancel()
    }

    private func run(_ chain: [VoiceModelEntry]) async throws {
        for entry in chain where states[entry.id] != .ready {
            let fetch: Task<Void, Error>
            if let running = fetches[entry.id] {
                fetch = running
            } else {
                fetch = Task { try await self.fetch(entry) }
                fetches[entry.id] = fetch
            }
            try await withTaskCancellationHandler {
                try await fetch.value
            } onCancel: {
                fetch.cancel()
            }
        }
    }

    private func fetch(_ entry: VoiceModelEntry) async throws {
        let id = entry.id
        defer { fetches[id] = nil }
        failures[id] = nil
        do {
            let partial = try preparePartial(entry)
            var done = Self.receivedBytes(of: entry, in: partial)
            states[id] = .downloading(received: done)
            publish()
            for source in entry.sources {
                for file in source.files {
                    try Task.checkCancellation()
                    let base = done
                    try await Self.downloadFile(
                        file, of: source, into: partial, http: http, host: host, limits: limits
                    ) { [weak self] received in
                        Task { await self?.progress(id, base + received) }
                    }
                    done = base + file.size
                    states[id] = .downloading(received: done)
                    publish()
                }
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

    private func progress(_ id: String, _ received: Int64) {
        guard case .downloading(let now) = states[id], received > now else { return }
        states[id] = .downloading(received: received)
        publish()
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

    // MARK: - Delete

    /// Deletes a model and clears the CoreML cache. Refuses while an engine
    /// holds the model; stops its download first. The administrator's folder
    /// is never touched.
    public func delete(_ id: String) async throws {
        guard entry(id) != nil else { throw VoiceModelFailure.unknownModel(id) }
        guard holders[id] == nil else { throw VoiceModelFailure.inUse(id) }
        await stopDownload(id)
        guard holders[id] == nil else { throw VoiceModelFailure.inUse(id) }
        try removeUserCopy(id)
        clearCoreMLCache()
        publish()
    }

    /// Deletes every model no engine holds, and what older catalogs left.
    /// Returns the ids it kept because they are in use.
    @discardableResult
    public func deleteAll() async throws -> [String] {
        for id in Array(downloads.keys) + Array(fetches.keys) where holders[id] == nil {
            await stopDownload(id)
        }
        var kept: [String] = []
        for entry in catalog {
            if holders[entry.id] != nil {
                kept.append(entry.id)
            } else {
                try removeUserCopy(entry.id)
            }
        }
        try removeLeftovers(keeping: Set(kept))
        clearCoreMLCache()
        publish()
        return kept
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

    /// Clears the CoreML cache, or marks it to clear once no engine holds a model.
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

    private func status(_ entry: VoiceModelEntry) -> VoiceModelStatus {
        VoiceModelStatus(
            entry: entry, state: states[entry.id] ?? .absent, isInUse: holders[entry.id] != nil,
            isManaged: managed.voiceModelDownloadsDisabled, failure: failures[entry.id])
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
        entry.sources.reduce(0) { total, source in
            source.files.reduce(total) { total, file in
                let target = partial.appending(path: file.path)
                if size(of: target) == file.size { return total + file.size }
                return total + min(file.size, size(of: partURL(target)) ?? 0)
            }
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
    /// the actor. `progress` gets the bytes of this file so far.
    static func downloadFile(
        _ file: VoiceModelFile, of source: VoiceModelSource, into folder: URL, http: VoiceHTTP, host: String,
        limits: Limits, progress: @escaping @Sendable (Int64) -> Void
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

        /// A finished `.part`: into place, or removed for another try.
        func settle(_ digest: String) throws -> Bool {
            if digest == file.sha256 {
                try rename(part, to: target)
                progress(file.size)
                return true
            }
            try? manager.removeItem(at: part)
            checksumFailures += 1
            log.error("\(file.path, privacy: .public): checksum mismatch, try \(checksumFailures)")
            if checksumFailures >= limits.checksumAttempts { throw VoiceModelFailure.checksumMismatch(file.path) }
            return false
        }

        func failed(_ failure: VoiceModelFailure, progressed: Bool) async throws {
            networkFailures = progressed ? 1 : networkFailures + 1
            if networkFailures >= limits.networkAttempts { throw failure }
            try await Task.sleep(for: limits.retryDelay(networkFailures))
        }

        while true {
            try Task.checkCancellation()
            let offset = size(of: part) ?? 0
            if offset > file.size {
                try? manager.removeItem(at: part)
                continue
            }
            if offset == file.size {
                if try settle(try sha256(of: part)) { return }
                continue
            }

            let writer: PartWriter
            do {
                writer = try PartWriter(url: part, offset: offset, progress: progress)
            } catch {
                throw VoiceModelFailure.disk(String(describing: error))
            }
            var request = URLRequest(url: origin)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

            let response: HTTPURLResponse
            do {
                response = try await http.stream(
                    request, purpose: .modelDownload, accept: { writer.begin($0, expectedSize: file.size) },
                    receive: { try writer.write($0) })
            } catch is CancellationError {
                writer.close()
                throw CancellationError()
            } catch is VoiceHTTP.Failure {
                writer.close()
                throw VoiceModelFailure.voiceDisabled
            } catch let error as PartWriter.Overflow {
                writer.close()
                try? manager.removeItem(at: part)
                try await failed(.network(String(describing: error)), progressed: false)
                continue
            } catch {
                writer.close()
                let progressed = writer.written > 0
                try await failed(.network(error.localizedDescription), progressed: progressed)
                continue
            }
            writer.close()

            let status = response.statusCode
            let responseHost = response.url?.host() ?? originHost
            let redirected = response.url != origin
            switch status {
            case 200, 206:
                guard writer.started else {
                    // A 206 for other bytes than asked: start over.
                    try? manager.removeItem(at: part)
                    try await failed(.http(status: status, host: responseHost), progressed: false)
                    continue
                }
                let total = writer.offset + writer.written
                if total < file.size {
                    // The connection closed early without an error.
                    try await failed(.network("\(file.path): \(total) of \(file.size) bytes"), progressed: writer.written > 0)
                    continue
                }
                if try settle(writer.digest()) { return }
            case 416:
                // Nothing past `offset`: the part may be whole already.
                guard let whole = try? sha256(of: part) else {
                    try await failed(.http(status: status, host: responseHost), progressed: false)
                    continue
                }
                if try settle(whole) { return }
            case 403 where redirected, 410 where redirected:
                // The signed CDN link expired: ask the origin for a fresh one.
                expiredLinks += 1
                log.info("\(file.path, privacy: .public): CDN link expired (\(status)), asking \(originHost, privacy: .public) again")
                if expiredLinks >= limits.expiredLinks { throw VoiceModelFailure.http(status: status, host: responseHost) }
            case 408, 429, 500...599:
                try await failed(.http(status: status, host: responseHost), progressed: false)
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
    struct Overflow: Error, CustomStringConvertible {
        let description: String
    }

    let url: URL
    private(set) var offset: Int64
    private(set) var written: Int64 = 0
    private(set) var started = false
    private var expected: Int64 = 0
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var prefixHasher: SHA256
    private var reported: Int64 = 0
    private let progress: @Sendable (Int64) -> Void

    /// Hashes the bytes already in the file, so a resumed file is not read twice.
    init(url: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) throws {
        self.url = url
        self.offset = offset
        self.progress = progress
        var prefix = SHA256()
        if offset > 0 {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            var left = offset
            while left > 0, let chunk = try reader.read(upToCount: Int(min(left, 4 << 20))), !chunk.isEmpty {
                prefix.update(data: chunk)
                left -= Int64(chunk.count)
            }
        }
        prefixHasher = prefix
    }

    /// Takes a 200 from the start and a 206 from exactly `offset`; anything
    /// else is left unread.
    func begin(_ response: HTTPURLResponse, expectedSize: Int64) -> Bool {
        expected = expectedSize
        switch response.statusCode {
        case 200:
            offset = 0
            hasher = SHA256()
        case 206:
            guard Self.rangeStart(response.value(forHTTPHeaderField: "Content-Range")) == offset else { return false }
            hasher = prefixHasher
        default:
            return false
        }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seek(toOffset: UInt64(offset))
            self.handle = handle
        } catch {
            return false
        }
        started = true
        return true
    }

    func write(_ data: Data) throws {
        guard let handle else { return }
        guard offset + written + Int64(data.count) <= expected else {
            throw Overflow(description: "\(url.lastPathComponent): more bytes than \(expected)")
        }
        try handle.write(contentsOf: data)
        hasher.update(data: data)
        written += Int64(data.count)
        let now = offset + written
        if now - reported >= 256 << 10 || now == expected {
            reported = now
            progress(now)
        }
    }

    /// Flushes to disk, so a file renamed into place after a crash holds its bytes.
    func close() {
        guard let handle else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
    }

    func digest() -> String { VoiceModelStore.hex(hasher.finalize()) }

    /// The first byte of `bytes <first>-<last>/<size>`.
    static func rangeStart(_ header: String?) -> Int64? {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let range = header.dropFirst(6).prefix { $0 != "/" }
        guard let first = range.split(separator: "-").first else { return nil }
        return Int64(first)
    }
}
