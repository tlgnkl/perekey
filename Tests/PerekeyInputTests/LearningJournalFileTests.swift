// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct LearningJournalFileTests {
    @Test func fileIsForTheOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LearningJournalFile(url: directory.appending(path: "learning-journal.json"))
        let report = UndoReport(word: "jrtq", app: "com.apple.Notes", channel: .button, threshold: 2,
                                facts: UndoFacts(kind: .layout, decision: nil))
        let entry = LearningJournal.Entry(undo: report, step: LearningStep(outcome: .counted, oldRule: .learn), at: 1)
        for _ in 0..<2 {
            try file.append(entry)
            let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        #expect(file.load().entries.count == 2)
    }

    @Test func anOpenFileIsClosedToTheOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = LearningJournalFile(url: directory.appending(path: "learning-journal.json"))
        try Data("{}".utf8).write(to: file.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        try file.save(LearningJournal())
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["learning-journal.json"])
    }
}
