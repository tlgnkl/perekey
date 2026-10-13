// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyInput
import PerekeyVoiceCore
import Testing

struct VoiceModesFileTests {
    private func temporaryFile() throws -> (VoiceModesFile, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-modes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (VoiceModesFile(url: directory.appending(path: "voice-modes.json")), directory)
    }

    @Test func noFileGivesTheDefaults() throws {
        let (file, directory) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(file.load(defaults: .defaults()) == .defaults())
    }

    @Test func roundTripKeepsUnknownKeys() throws {
        let (file, directory) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"schemaVersion":1,"fromTheFuture":{"a":1}}"#.utf8).write(to: file.url)
        var modes = file.load(defaults: .defaults())
        modes.consent([.text], endpoint: "openai")
        modes.pinnedModeID = "mail"
        try file.save(modes)
        #expect(file.load(defaults: .defaults()) == modes)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any]
        #expect(object?["fromTheFuture"] != nil)
        // No key ever reaches the file.
        #expect(!String(decoding: try Data(contentsOf: file.url), as: UTF8.self).contains("sk-"))
    }

    @Test func aNewerFileIsNeverOverwritten() throws {
        let (file, directory) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let newer = Data(#"{"schemaVersion":5,"modes":[{"id":"x","name":"X"}],"defaultModeID":"x"}"#.utf8)
        try newer.write(to: file.url)
        let read = file.load(defaults: .defaults())
        #expect(read.newerSchemaVersion == 5)
        #expect(read.modes.map(\.id) == ["x"])
        let error = #expect(throws: VoiceModesFile.NewerVersionError.self) { try file.save(read) }
        #expect(error?.schemaVersion == 5)
        #expect(try Data(contentsOf: file.url) == newer)
    }

    @Test func aFileWithUnreadableValuesIsNeverOverwritten() throws {
        let (file, directory) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = Data(#"{"schemaVersion":1,"defaultModeID":"a","modes":[{"id":"a","name":"A","output":"pasteAndShout"}]}"#.utf8)
        try written.write(to: file.url)
        var read = file.load(defaults: .defaults())
        #expect(read.mode("a") != nil)
        #expect(read.isReadOnly)
        read.pinnedModeID = "a"
        #expect(throws: VoiceModesFile.UnreadableContentError.self) { try file.save(read) }
        #expect(try Data(contentsOf: file.url) == written)
    }

    @Test func aBrokenFileIsSetAside() throws {
        let (file, directory) = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{ not json".utf8).write(to: file.url)
        #expect(file.load(defaults: .defaults()) == .defaults())
        #expect(FileManager.default.fileExists(atPath: file.brokenURL.path))
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}
