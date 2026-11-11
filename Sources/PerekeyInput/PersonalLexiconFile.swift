// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The personal lexicon (`PersonalLexiconModel`) as JSON in Application
/// Support, next to the settings but not in them: every settings change is a
/// full write of `settings.json` and a new snapshot for the tap, and the
/// lexicon changes every few dozen words. The settings export leaves it out
/// by not knowing it.
///
/// The file holds keyed fingerprints in hex, language codes, counts and day
/// numbers. Never a word: a fingerprint under the key in the Keychain says
/// nothing without the key (docs/classifier.md, «Личный словарь», «Что
/// хранится»). The file is for the owner only, from its first byte.
public struct PersonalLexiconFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "lexicon.json", directoryHint: .notDirectory)
    }

    public init(url: URL = PersonalLexiconFile.defaultURL) {
        self.url = url
    }

    /// The format this build writes and reads.
    public static let currentVersion = 1

    /// What the file says about one word or candidate.
    struct Record: Codable, Equatable {
        var fingerprint: String
        var language: String
        var count: Int
        var days: Int
        var lastDay: Int
        var accepted: Bool
        /// The starts of an accepted word only (`PersonalLexiconModel.Entry`).
        var start3: String?
        var start4: String?
    }

    struct Document: Codable, Equatable {
        var version: Int
        /// A fingerprint of a constant under the key that wrote the file:
        /// with another key (the Keychain item was lost, or erased and made
        /// again) the fingerprints below match no word, and the file is let go.
        var keyCheck: String
        var entries: [Record]
    }

    /// What the file is under `key`, as a counting model with `options`.
    /// No file, an unreadable one, one of another version and one written
    /// under another key all give an empty model: nothing is set aside and
    /// nothing throws. The next save replaces the file.
    public func load(key: PersonalKey, options: PersonalOptions = PersonalOptions(),
                     generation: UInt32 = 0) -> PersonalLexiconModel
    {
        let empty = PersonalLexiconModel(options: options, generation: generation)
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == Self.currentVersion, document.keyCheck == Self.keyCheck(key)
        else { return empty }
        var entries: [UInt64: PersonalLexiconModel.Entry] = [:]
        for record in document.entries {
            guard let fingerprint = Self.parse(record.fingerprint), let language = LanguageCode(record.language),
                  record.count >= 1, record.days >= 1, record.days <= record.count
            else { return empty }
            let start3 = record.start3.flatMap(Self.parse)
            let start4 = record.start4.flatMap(Self.parse)
            // A start that is there and not a fingerprint is a damaged file, not a word without one.
            guard (record.start3 == nil) == (start3 == nil), (record.start4 == nil) == (start4 == nil) else { return empty }
            entries[fingerprint] = PersonalLexiconModel.Entry(
                language: language, start3: start3, start4: start4, count: record.count, days: record.days,
                lastDay: record.lastDay, accepted: record.accepted)
        }
        return PersonalLexiconModel(options: options, entries: entries, generation: generation)
    }

    /// The names of the files `save` makes before the replace. Only these are
    /// swept: the folder holds the files of other writers too.
    static let temporaryPrefix = ".lexicon-"
    static let temporarySuffix = ".tmp"

    /// Writes the lexicon: atomically, 0600 from the first byte. The
    /// temporary file is made with the mode 0600 (`open`, not a copy of the
    /// umask's), written through its descriptor and closed; the mode is set
    /// again before the replace, and read after it. A temporary file left by
    /// an earlier crash is swept first.
    public func save(_ model: PersonalLexiconModel, key: PersonalKey) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sweepTemporaries()
        let data = try Self.encode(model, key: key)
        let (temporary, handle) = try Self.createTemporary(in: directory)
        do {
            try handle.write(contentsOf: data)
            guard fchmod(handle.fileDescriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            // The replace may keep the old file's mode: a file left 0644 stays 0644 without this.
            try Self.requireOwnerOnly(url)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Makes a new file with the mode 0600 and a name nobody has.
    static func createTemporary(in directory: URL) throws -> (URL, FileHandle) {
        let url = directory.appending(path: "\(temporaryPrefix)\(UUID().uuidString)\(temporarySuffix)")
        return (url, try openExclusively(url))
    }

    /// `open(O_CREAT | O_EXCL)` with the mode 0600; fails if the file is there.
    static func openExclusively(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Sets the mode 0600 and reads it back; throws when the file is not the owner's alone after it.
    private static func requireOwnerOnly(_ url: URL) throws {
        let manager = FileManager.default
        func mode() throws -> Int? {
            try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        if try mode() != 0o600 {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        guard try mode() == 0o600 else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// Deletes the temporary files of this lexicon that a crash left.
    private func sweepTemporaries() {
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(Self.temporaryPrefix) && name.hasSuffix(Self.temporarySuffix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// Deletes the file and the temporary files a crash left; no file is not an error.
    public func remove() throws {
        sweepTemporaries()
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The bytes `save` writes: sorted keys, entries in the order of their fingerprints.
    public static func encode(_ model: PersonalLexiconModel, key: PersonalKey) throws -> Data {
        let records = model.entries.sorted { $0.key < $1.key }.map { fingerprint, entry in
            Record(fingerprint: hex(fingerprint), language: entry.language.text, count: entry.count, days: entry.days,
                   lastDay: entry.lastDay, accepted: entry.accepted, start3: entry.start3.map(hex),
                   start4: entry.start4.map(hex))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(version: currentVersion, keyCheck: keyCheck(key), entries: records))
    }

    /// The fingerprint of a constant under the key: the empty word of a
    /// language no layout has. No word of the user has this fingerprint, and
    /// nothing is learned from it.
    static func keyCheck(_ key: PersonalKey) -> String {
        hex(key.fingerprint(.word, language: "--", EmptyCollection<UInt32>()))
    }

    /// 16 lowercase hex digits.
    static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    /// The value of exactly 16 lowercase hex digits; nil for anything else.
    static func parse(_ text: String) -> UInt64? {
        guard text.utf8.count == 16, text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
        else { return nil }
        return UInt64(text, radix: 16)
    }
}
