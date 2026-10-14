// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Where recordings live: `Perekey/Recordings/<id>/` in Application Support,
/// beside `History`, with `meta.json`, `transcript.json` and a call's audio.
///
/// The whole folder is kept out of Time Machine (`isExcludedFromBackup`)
/// unless the user includes it: calls hold other people's voices. The mark
/// is on the folder, so atomic writes inside, which replace the files, do
/// not lose it.
///
/// Both files are versioned as `VoiceSettingsFile` is: one of a newer
/// `schemaVersion` is read as such and never written over. The recorder,
/// the queue and the window all change them, so every change goes through
/// `updateMeta` or `updateTranscript`: a read, the change and an atomic
/// write under one lock, and no change undoes another.
public struct RecordingsFolder: Sendable {
    public let root: URL

    /// One for all folders: the files are small, and writes are rare.
    private static let lock = OSAllocatedUnfairLock()
    private static let log = Logger(subsystem: "app.perekey", category: "recordings")

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "Recordings", directoryHint: .isDirectory)
    }

    public init(root: URL = RecordingsFolder.defaultRoot) {
        self.root = root
    }

    public func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    public func metaURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "meta.json", directoryHint: .notDirectory)
    }

    public func transcriptURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "transcript.json", directoryHint: .notDirectory)
    }

    /// A file as the disk holds it.
    public enum Loaded<Value: Sendable>: Sendable {
        case missing
        case loaded(Value)
        /// Written by a newer Perekey: shown as unknown, never written.
        case newer(schemaVersion: Int)
        case unreadable
    }

    /// Why a file could not be changed.
    public enum FileError: Error, Equatable {
        case missing
        case unreadable
        /// A newer Perekey wrote it: it is left alone.
        case newerVersion(Int)
    }

    /// A new recording's folder and its `meta.json`. `excludedFromBackup` is
    /// the user's Time Machine choice; it is set on the whole folder each
    /// time, so a mark that failed once is set again with the next recording.
    @discardableResult
    public func create(_ meta: RecordingMeta, id: UUID = UUID(), excludedFromBackup: Bool) throws -> UUID {
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        do {
            try setExcludedFromBackup(excludedFromBackup)
        } catch {
            // No paths: they hold the user's name.
            let error = error as NSError
            Self.log.error("Time Machine mark failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        }
        try Self.lock.withLockUnchecked {
            try write(meta, to: metaURL(for: id), current: RecordingMeta.schemaVersion,
                      ownKeys: RecordingMeta.CodingKeys.allCases.map(\.rawValue))
        }
        return id
    }

    /// The ids of the recordings on disk, in no order.
    public func recordings() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    public func meta(_ id: UUID) -> Loaded<RecordingMeta> {
        Self.lock.withLockUnchecked { load(metaURL(for: id), current: RecordingMeta.schemaVersion) }
    }

    /// Changes `meta.json`: the one way to write it after `create`. Keys a
    /// newer version added at the top level stay; nested ones do not.
    /// Throws `FileError` if there is no file this version may write.
    @discardableResult
    public func updateMeta(_ id: UUID, _ change: (inout RecordingMeta) throws -> Void) throws -> RecordingMeta {
        try Self.lock.withLockUnchecked {
            var meta: RecordingMeta = try value(of: load(metaURL(for: id), current: RecordingMeta.schemaVersion))
            try change(&meta)
            try write(meta, to: metaURL(for: id), current: RecordingMeta.schemaVersion,
                      ownKeys: RecordingMeta.CodingKeys.allCases.map(\.rawValue))
            return meta
        }
    }

    public func transcript(_ id: UUID) -> Loaded<TranscriptDocument> {
        Self.lock.withLockUnchecked { load(transcriptURL(for: id), current: TranscriptDocument.schemaVersion) }
    }

    /// Changes `transcript.json`, or writes the first one: the change gets
    /// nil when there is none, and nil left by it writes nothing. A new
    /// transcript replaces the old one whole, with only what the change
    /// keeps of it (`keepingNames`). Throws `FileError` for a file this
    /// version may not write.
    public func updateTranscript(_ id: UUID, _ change: (inout TranscriptDocument?) throws -> Void) throws {
        try Self.lock.withLockUnchecked {
            var document: TranscriptDocument?
            switch load(transcriptURL(for: id), current: TranscriptDocument.schemaVersion) as Loaded<TranscriptDocument> {
            case .missing: document = nil
            case let .loaded(value): document = value
            case let .newer(version): throw FileError.newerVersion(version)
            case .unreadable: throw FileError.unreadable
            }
            try change(&document)
            guard let document else { return }
            try write(document, to: transcriptURL(for: id), current: TranscriptDocument.schemaVersion, ownKeys: nil)
        }
    }

    /// Removes a recording: its folder with the audio and the transcript.
    /// A file the user chose is outside it and stays.
    public func remove(_ id: UUID) throws {
        try Self.lock.withLockUnchecked { try FileManager.default.removeItem(at: directory(for: id)) }
    }

    /// The Time Machine choice: «Включать в Time Machine» clears the mark.
    public func setExcludedFromBackup(_ excluded: Bool) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    public var isExcludedFromBackup: Bool {
        // A URL caches what it read; ask the disk.
        var url = root
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct Version: Decodable {
        var schemaVersion: Int
    }

    private func value<Value>(of loaded: Loaded<Value>) throws -> Value {
        switch loaded {
        case let .loaded(value): value
        case .missing: throw FileError.missing
        case .unreadable: throw FileError.unreadable
        case let .newer(version): throw FileError.newerVersion(version)
        }
    }

    private func load<Value: Decodable & Sendable>(_ url: URL, current: Int) -> Loaded<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        let decoder = Self.decoder()
        guard let version = try? decoder.decode(Version.self, from: data) else { return .unreadable }
        if version.schemaVersion > current { return .newer(schemaVersion: version.schemaVersion) }
        guard let value = try? decoder.decode(Value.self, from: data) else { return .unreadable }
        return .loaded(value)
    }

    /// Writes atomically. With `ownKeys`, the file's other top-level keys
    /// stay: a newer version may have added them. Its own keys are dropped
    /// first, so a field set back to nil does not come back from the disk.
    private func write(_ value: some Encodable, to url: URL, current: Int, ownKeys: [String]?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object: [String: Any] = [:]
        if let theirs = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) })
            as? [String: Any]
        {
            if let version = theirs["schemaVersion"] as? Int, version > current {
                throw FileError.newerVersion(version)
            }
            if let ownKeys { object = theirs.filter { !ownKeys.contains($0.key) } }
        }
        let ours = try JSONSerialization.jsonObject(with: Self.encoder().encode(value)) as? [String: Any] ?? [:]
        object.merge(ours) { _, new in new }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
