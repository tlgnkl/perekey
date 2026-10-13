// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import PerekeyCore
import PerekeyVoiceCore

/// The history as the disk holds it: `history.json` and the audio files of
/// dictations, in a folder of their own, `Perekey/History`.
///
/// The folder and every file in it are kept out of Time Machine
/// (`isExcludedFromBackup`): a backup would keep the text past the term the
/// user chose. The folder is separate so that the settings beside it stay in
/// the backup. Atomic writes replace the file and drop the mark on it, so the
/// mark is set again after each write, and the folder's covers the rest.
///
/// A file of a newer `schemaVersion` is read and never written. A file that
/// cannot be read is moved aside.
public struct DictationHistoryFile: Sendable {
    public static let schemaVersion = 1

    public let directory: URL

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "History", directoryHint: .isDirectory)
    }

    public init(directory: URL = DictationHistoryFile.defaultDirectory) {
        self.directory = directory
    }

    public var url: URL { directory.appending(path: "history.json", directoryHint: .notDirectory) }
    public var brokenURL: URL { directory.appending(path: "history.broken.json", directoryHint: .notDirectory) }
    public var audioDirectory: URL { directory.appending(path: "Audio", directoryHint: .isDirectory) }

    public func audioURL(for id: UUID) -> URL {
        audioDirectory.appending(path: id.uuidString.lowercased() + ".aac", directoryHint: .notDirectory)
    }

    struct Document: Codable {
        var schemaVersion: Int
        var entries: [HistoryEntry]
    }

    public struct Loaded: Sendable {
        public var entries: [HistoryEntry]
        /// The file is of a newer version: shown, never written.
        public var newerSchemaVersion: Int?
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Entries oldest first. None if there is no file.
    public func load() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Loaded(entries: [])
        } catch {
            setAside()
            return Loaded(entries: [])
        }
        if let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int,
           version > Self.schemaVersion
        {
            let entries = (try? Self.decoder().decode(Document.self, from: data))?.entries ?? []
            return Loaded(entries: entries, newerSchemaVersion: version)
        }
        guard let document = try? Self.decoder().decode(Document.self, from: data) else {
            setAside()
            return Loaded(entries: [])
        }
        return Loaded(entries: document.entries)
    }

    public func save(_ entries: [HistoryEntry]) throws {
        try prepareDirectory()
        let data = try Self.encoder().encode(Document(schemaVersion: Self.schemaVersion, entries: entries))
        try data.write(to: url, options: .atomic)
        Self.excludeFromBackup(url)
    }

    /// Creates the folders, kept out of the backup.
    public func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
    }

    public func writeAudio(_ samples: [Float], sampleRate: Double, id: UUID) throws {
        try prepareDirectory()
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(audioDirectory)
        let target = audioURL(for: id)
        try AACWriter.write(samples: samples, sampleRate: sampleRate, to: target)
        Self.excludeFromBackup(target)
    }

    public func removeAudio(_ id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
    }

    /// Audio files in the folder, by the id in the name.
    public func audioIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: audioDirectory.path)) ?? []
        return Set(names.compactMap { name in
            name.hasSuffix(".aac") ? UUID(uuidString: String(name.dropLast(4))) : nil
        })
    }

    public func removeAllAudio() {
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    /// Half-written audio (`*.part.aac`) a crash left behind.
    public func removeStrayParts() {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: audioDirectory.path)) ?? [] where name.contains(".part.") {
            try? manager.removeItem(at: audioDirectory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// The history a damaged file was moved to holds texts too: it goes with the term.
    public func removeBroken(olderThan cutoff: Date) {
        let modified = (try? brokenURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff { try? FileManager.default.removeItem(at: brokenURL) }
    }

    /// Removes everything the history has on disk.
    public func eraseAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func setAside() {
        let manager = FileManager.default
        try? manager.removeItem(at: brokenURL)
        try? manager.moveItem(at: url, to: brokenURL)
    }
}

/// One finished dictation, as the controller hands it to the history.
public struct DictationRecord {
    public var text: String
    public var bundleID: String?
    public var appName: String?
    /// The host of the page in front, if it is a browser.
    public var host: String?
    public var duration: Double
    public var model: String
    public var pasted: Bool
    public var privacy: DictationPrivacy
    /// 16 kHz mono speech, kept only if the user asked for it.
    public var audio: [Float]?

    public init(text: String, bundleID: String? = nil, appName: String? = nil, host: String? = nil, duration: Double,
                model: String, pasted: Bool, privacy: DictationPrivacy = .normal, audio: [Float]? = nil)
    {
        self.text = text
        self.bundleID = bundleID
        self.appName = appName
        self.host = host
        self.duration = duration
        self.model = model
        self.pasted = pasted
        self.privacy = privacy
        self.audio = audio
    }
}

/// The dictation history in memory (newest first) and on disk.
///
/// Nothing runs while idle: expired entries go at launch, and then at most
/// once a day when a dictation is recorded or the menu opens.
/// Texts never go to a log, not even a private one.
@MainActor
@Observable
public final class DictationHistory {
    /// What `record` did.
    public enum Outcome: Equatable, Sendable {
        case recorded
        case skipped(Reason)

        public enum Reason: Equatable, Sendable {
            case retentionOff, privateField, excludedApp, readOnly, emptyText
        }
    }

    /// The most entries kept whatever the term says; bounds the file.
    public static let capacity = 1000
    public static let purgeInterval: TimeInterval = 24 * 3600

    public private(set) var entries: [HistoryEntry]
    /// The file was written by a newer Perekey: shown, not changed.
    public private(set) var isReadOnly: Bool
    /// Moves on every change, so views redraw.
    public private(set) var revision = 0

    @ObservationIgnored private let file: DictationHistoryFile
    @ObservationIgnored private let settings: @MainActor () -> VoiceTextSettings
    @ObservationIgnored private let managed: ManagedSettings
    /// Programs and sites the voice exclusions name: nothing from them is kept.
    /// The exclusion list of dictation plugs in here.
    @ObservationIgnored private let isExcluded: @MainActor (_ bundleID: String?, _ host: String?) -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sampleRate: Double
    @ObservationIgnored private var lastPurge: Date
    /// Everything that touches the disk runs here, one job after another: the
    /// AAC encoder and the JSON writer take seconds on a long recording, and
    /// the main thread (the HUD) must not wait for them.
    @ObservationIgnored private let disk = DispatchQueue(label: "app.perekey.history-disk", qos: .utility)

    public init(
        file: DictationHistoryFile = DictationHistoryFile(), managed: ManagedSettings = ManagedSettings(),
        sampleRate: Double = VoiceCore.sampleRate,
        settings: @escaping @MainActor () -> VoiceTextSettings,
        isExcluded: @escaping @MainActor (_ bundleID: String?, _ host: String?) -> Bool = { _, _ in false },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.file = file
        self.managed = managed
        self.sampleRate = sampleRate
        self.settings = settings
        self.isExcluded = isExcluded
        self.now = now
        let loaded = file.load()
        entries = loaded.entries.sorted { $0.date > $1.date }
        isReadOnly = loaded.newerSchemaVersion != nil
        lastPurge = now()
        purge()
    }

    /// The term in force: the user's choice cut down by the profile.
    public var retention: HistoryRetention {
        settings().retention.limited(byMaxDays: managed.voiceHistoryMaxDays)
    }

    /// The audio is kept: the user asked for it and the history is on.
    public var keepsAudio: Bool { settings().keepsAudio && retention != .off }

    public var folderURL: URL { file.directory }

    // MARK: Recording

    @discardableResult
    public func record(_ item: DictationRecord) -> Outcome {
        guard !isReadOnly else { return .skipped(.readOnly) }
        guard retention != .off else { return .skipped(.retentionOff) }
        guard item.privacy == .normal else { return .skipped(.privateField) }
        guard !isExcluded(item.bundleID, item.host) else { return .skipped(.excludedApp) }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .skipped(.emptyText) }

        purgeIfDue()
        var entry = HistoryEntry(
            text: text, bundleID: item.bundleID, appName: item.appName, date: now(), duration: item.duration,
            model: item.model, pasted: item.pasted)
        if keepsAudio, let samples = item.audio, !samples.isEmpty {
            // The file follows on the disk queue; `audioURL(of:)` checks it is there.
            entry.hasAudio = true
            let file = self.file, sampleRate = self.sampleRate, id = entry.id
            disk.async { try? file.writeAudio(samples, sampleRate: sampleRate, id: id) }
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            let dropped = entries[Self.capacity...].filter(\.hasAudio).map(\.id)
            entries.removeLast(entries.count - Self.capacity)
            let file = self.file
            disk.async { dropped.forEach(file.removeAudio) }
        }
        persist()
        return .recorded
    }

    // MARK: Cleaning

    /// Cleans by the term when a day has passed since the last time. Call it
    /// when a dictation is recorded and when the menu opens.
    public func purgeIfDue() {
        // The oldest entry past the term does not wait for the day: with "1 day" it would live almost two.
        let expired = entries.last.map { $0.date < cutoff(for: retention) } ?? false
        guard now().timeIntervalSince(lastPurge) >= Self.purgeInterval || now() < lastPurge || expired else { return }
        purge()
    }

    private func cutoff(for term: HistoryRetention) -> Date {
        now().addingTimeInterval(-Double(term.days) * 24 * 3600)
    }

    /// Removes what is past the term, and the audio nobody points at.
    public func purge() {
        lastPurge = now()
        guard !isReadOnly else { return }
        let term = retention
        let before = entries.count
        let file = self.file
        if term == .off {
            entries = []
            disk.async { file.eraseAll() }
            if before > 0 { revision += 1 }
            return
        }
        let cutoff = cutoff(for: term)
        let kept = entries.filter { $0.date >= cutoff }
        var changed = kept.count != entries.count
        var gone = entries.filter { $0.date < cutoff && $0.hasAudio }.map(\.id)
        entries = kept
        if !keepsAudio {
            for index in entries.indices where entries[index].hasAudio {
                gone.append(entries[index].id)
                entries[index].hasAudio = false
                changed = true
            }
        }
        let known = Set(entries.filter(\.hasAudio).map(\.id))
        disk.async {
            gone.forEach(file.removeAudio)
            // Audio nobody points at, a half-written file a crash left, a broken history past the term.
            for orphan in file.audioIDs().subtracting(known) { file.removeAudio(orphan) }
            file.removeStrayParts()
            file.removeBroken(olderThan: cutoff)
        }
        if changed { persist() }
    }

    /// The settings changed: the term or the audio switch may now ask for a clean.
    public func settingsChanged() {
        purge()
    }

    /// The "Clear history" button.
    ///
    /// Also with a file of a newer version: deleting is not overwriting, and
    /// the user asked for the texts to go. New dictations are kept again after.
    public func clear() {
        entries = []
        isReadOnly = false
        let file = self.file
        disk.async { file.eraseAll() }
        revision += 1
    }

    public func remove(_ id: UUID) {
        guard !isReadOnly, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].hasAudio {
            let file = self.file
            disk.async { file.removeAudio(id) }
        }
        entries.remove(at: index)
        persist()
    }

    // MARK: Reading

    /// The newest `count` entries.
    public func recent(_ count: Int = 20) -> [HistoryEntry] {
        Array(entries.prefix(count))
    }

    public func audioURL(of entry: HistoryEntry) -> URL? {
        guard entry.hasAudio else { return nil }
        let url = file.audioURL(for: entry.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Waits for the disk jobs queued so far. For tests and for quit.
    public func flush() {
        disk.sync {}
    }

    private func persist() {
        revision += 1
        // Oldest first on disk, so an append is a tail change in a diff.
        let snapshot = Array(entries.reversed())
        let file = self.file
        disk.async { try? file.save(snapshot) }
    }
}
