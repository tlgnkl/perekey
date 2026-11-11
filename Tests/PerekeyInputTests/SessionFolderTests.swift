// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
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
            recorder.write([.snapshot(InputMachine().snapshot, nil, newFile: true)], close: true) { _, _ in }
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

    /// The release check looks for the marker the recorder carries.
    @Test func theReleaseCheckLooksForTheRecordersMarker() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/check-no-recorder.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains(#"MARKER="\#(SessionRecorder.marker)""#))
    }
}
#endif
