// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where recordings live: `Perekey/Recordings/<id>/` in Application Support,
/// beside `History`, with `meta.json`, `transcript.json` and a call's audio.
///
/// The whole folder is kept out of Time Machine (`isExcludedFromBackup`):
/// calls hold other people's voices, and the user chooses whether a backup
/// keeps them. The mark is on the folder, so atomic writes inside, which
/// replace the files, do not lose it.
///
/// Both files are versioned as `VoiceSettingsFile` is: one of a newer
/// `schemaVersion` is read as such and never written over.
public struct RecordingsFolder: Sendable {
    public let root: URL

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

    /// The file on disk is of a newer version: it is left alone.
    public struct NewerVersionError: Error, Equatable {
        public let schemaVersion: Int

        public init(schemaVersion: Int) {
            self.schemaVersion = schemaVersion
        }
    }

    /// A new recording's folder and its `meta.json`.
    @discardableResult
    public func create(_ meta: RecordingMeta, id: UUID = UUID()) throws -> UUID {
        let fresh = !FileManager.default.fileExists(atPath: root.path)
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        // The user's later choice is left alone: only a new folder is marked.
        if fresh { try? setExcludedFromBackup(true) }
        try save(meta, id: id)
        return id
    }

    /// The ids of the recordings on disk, in no order.
    public func recordings() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    public func meta(_ id: UUID) -> Loaded<RecordingMeta> {
        load(metaURL(for: id), current: RecordingMeta.schemaVersion)
    }

    /// Rewrites `meta.json` atomically. Keys this version does not know stay:
    /// a newer version may have added them to the same schema.
    public func save(_ meta: RecordingMeta, id: UUID) throws {
        try write(meta, to: metaURL(for: id), current: RecordingMeta.schemaVersion, keepingUnknownKeys: true)
    }

    public func transcript(_ id: UUID) -> Loaded<TranscriptDocument> {
        load(transcriptURL(for: id), current: TranscriptDocument.schemaVersion)
    }

    /// Writes `transcript.json` atomically, whole: a new transcript replaces
    /// the old one with all it had.
    public func save(_ transcript: TranscriptDocument, id: UUID) throws {
        try write(transcript, to: transcriptURL(for: id), current: TranscriptDocument.schemaVersion,
                  keepingUnknownKeys: false)
    }

    /// Removes a recording: its folder with the audio and the transcript.
    /// A file the user chose is outside it and stays.
    public func remove(_ id: UUID) throws {
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// The Time Machine choice; on by default, set at the first recording.
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

    private func write(_ value: some Encodable, to url: URL, current: Int, keepingUnknownKeys: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if let version = theirs["schemaVersion"] as? Int, version > current {
            throw NewerVersionError(schemaVersion: version)
        }
        var object = keepingUnknownKeys ? theirs : [:]
        let ours = try JSONSerialization.jsonObject(with: Self.encoder().encode(value)) as? [String: Any] ?? [:]
        object.merge(ours) { _, new in new }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
