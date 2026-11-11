// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
import os
import PerekeyCore
import Testing
@testable import PerekeyInput

/// Where the typing recorder keeps its files, and who may read them
/// (CONTRIBUTING.md, «Recording typing for the measure»).
@Suite struct SessionFolderTests {
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "perekey-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "sessions.noindex", directoryHint: .isDirectory)
        var folder: SessionFolder { SessionFolder(directory: directory) }

        deinit { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        /// Writes one recording: a header and a snapshot.
        func record(_ recorder: SessionRecorder) {
            recorder.write([.snapshot(InputMachine().snapshot, nil, newFile: true)], close: true) { _ in }
            recorder.drain()
        }

        func recorder() -> SessionRecorder {
            SessionRecorder(folder: folder, perekey: "0.3.0", build: "test")
        }
    }

    private func mode(_ url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    private func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    @Test func theFolderIsInApplicationSupportOutOfSpotlight() {
        let directory = SessionFolder.defaultDirectory
        #expect(directory.lastPathComponent == "sessions.noindex")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Perekey")
    }

    @Test func folderAndFilesAreForTheOwnerOnly() throws {
        let fixture = Fixture()
        // A folder someone made before, open to all.
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        fixture.record(fixture.recorder())
        let files = fixture.folder.files()
        #expect(files.count == 1)
        #expect(try mode(fixture.directory) == 0o700)
        for file in files { #expect(try mode(file) == 0o600) }
    }

    @Test func fileAndFolderStayOutOfTimeMachine() throws {
        let fixture = Fixture()
        fixture.record(fixture.recorder())
        #expect(isExcluded(fixture.directory))
        let file = try #require(fixture.folder.files().first)
        #expect(isExcluded(file))
    }

    /// A file starts with its header, then the snapshot: each one reads alone.
    @Test func aFileStartsWithItsHeader() throws {
        let fixture = Fixture()
        fixture.record(fixture.recorder())
        let file = try #require(fixture.folder.files().first)
        let text = try #require(String(data: Data(contentsOf: file), encoding: .utf8))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix(#"{"header":{"build":"test","format":"perekey-session","#))
        #expect(lines[1].hasPrefix(#"{"snapshot":"#))
    }

    @Test func recordingsLiveThirtyDays() throws {
        let fixture = Fixture()
        let recorder = fixture.recorder()
        fixture.record(recorder)
        fixture.record(recorder)
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let other = fixture.directory.appending(path: "notes.txt")
        try Data("x".utf8).write(to: other)
        let files = fixture.folder.files()
        #expect(files.count == 2)
        let now = Date()
        let old = now.addingTimeInterval(-SessionFolder.lifetime - 3600)
        let recent = now.addingTimeInterval(-SessionFolder.lifetime + 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: files[0].path)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: files[1].path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: other.path)
        #expect(fixture.folder.removeExpired(now: now) == 1)
        #expect(fixture.folder.files() == [files[1]])
        // Only recordings go.
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test func erasingRemovesEveryRecording() throws {
        let fixture = Fixture()
        let recorder = fixture.recorder()
        fixture.record(recorder)
        fixture.record(recorder)
        #expect(fixture.folder.files().count == 2)
        recorder.eraseAll()
        recorder.drain()
        #expect(fixture.folder.files().isEmpty)
    }

    /// A file older than 30 days goes when the day changes while the app
    /// runs, not only at launch.
    @Test func oldFilesGoWhenTheDayChanges() throws {
        let fixture = Fixture()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_762_780_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let recorder = SessionRecorder(folder: fixture.folder, perekey: "0.3.0", build: "test",
                                       calendar: calendar, now: { clock.withLock { $0 } })
        // Launch: the sweep of the day.
        recorder.removeExpired()
        recorder.drain()
        try fixture.folder.prepare()
        let old = fixture.directory.appending(path: "2025-09-01-1.pksession")
        #expect(FileManager.default.createFile(atPath: old.path, contents: Data("{}\n".utf8)))
        try FileManager.default.setAttributes([.modificationDate: clock.withLock { $0 }.addingTimeInterval(-40 * 24 * 3600)],
                                              ofItemAtPath: old.path)
        // The same day: a write does not sweep again.
        fixture.record(recorder)
        #expect(FileManager.default.fileExists(atPath: old.path))
        // The next day: the write sweeps.
        clock.withLock { $0 = $0.addingTimeInterval(24 * 3600) }
        fixture.record(recorder)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(fixture.folder.files().count == 2)
    }

    // MARK: - The release check

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The script on a file of `bytes`; `path` replaces PATH when given.
    private func check(_ bytes: Data, path: String? = nil) throws -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "Perekey")
        try bytes.write(to: binary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appending(path: "scripts/check-no-recorder.sh").path, binary.path]
        if let path { process.environment = ["PATH": path] }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func text(_ string: String) -> Data {
        Data(("plain text of a binary, long enough to be a string\0\0" + string + "\0end of the text").utf8)
    }

    @Test func theReleaseCheckLooksForTheRecordersMarker() throws {
        let script = try String(contentsOf: repository.appending(path: "scripts/check-no-recorder.sh"), encoding: .utf8)
        #expect(script.contains(#""\#(SessionRecorder.marker)""#))
        #expect(try check(text(SessionRecorder.marker)) == 1)
    }

    /// The second marker is on the side of the app: the badge in the menu bar.
    @Test func theReleaseCheckLooksForTheBadgeToo() throws {
        let marker = "app.perekey.recording-badge"
        let source = try String(contentsOf: repository.appending(path: "Sources/Perekey/SessionRecording.swift"),
                                encoding: .utf8)
        #expect(source.contains(#"marker = "\#(marker)""#))
        #expect(try check(text(marker)) == 1)
    }

    @Test func aBinaryWithNoMarkerPasses() throws {
        #expect(try check(text("nothing about recording here")) == 0)
    }

    /// `strings` that fails must not read as «no marker».
    @Test func aFailingStringsFailsTheCheck() throws {
        let tools = FileManager.default.temporaryDirectory.appending(path: "perekey-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tools) }
        let fake = tools.appending(path: "strings")
        try "#!/bin/bash\necho 'strings: broken' >&2\nexit 3\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let status = try check(text("nothing about recording here"), path: "\(tools.path):/usr/bin:/bin")
        #expect(status != 0)
    }

    /// A binary `strings` reads nothing from cannot be vouched for.
    @Test func aBinaryWithNoStringsIsNotAPass() throws {
        #expect(try check(Data(repeating: 0, count: 64)) == 2)
    }
}
#endif
