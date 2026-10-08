// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

@MainActor
@Suite struct UsageRecorderTests {
    private func tempFile() -> UsageStatsFile {
        UsageStatsFile(url: FileManager.default.temporaryDirectory
            .appending(path: "perekey-usage-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "statistics.json"))
    }

    @Test func offCountsAndWritesNothing() {
        let file = tempFile()
        let recorder = UsageRecorder(file: file, interval: 0) { false }
        recorder.recordCorrection(.layout)
        recorder.recordUndo()
        recorder.recordManualRetype()
        recorder.flush()
        #expect(recorder.stats.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func onWritesTheFileOnFlush() throws {
        let file = tempFile()
        defer { file.erase() }
        let recorder = UsageRecorder(file: file, interval: 3600) { true }
        recorder.recordCorrection(.typo)
        recorder.recordUndo()
        // The first write is immediate (nothing written yet); later ones wait.
        recorder.recordCorrection(.typo)
        recorder.flush()
        let saved = file.load()
        let day = saved.day(at: Date())
        #expect(day.correctionTotal == 2)
        #expect(day.undone == 1)
    }

    @Test func writesAreNotPerEvent() throws {
        let file = tempFile()
        defer { file.erase() }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let recorder = UsageRecorder(file: file, interval: 5, now: { clock }) { true }
        recorder.recordCorrection(.layout)          // written at once
        clock += 1
        recorder.recordCorrection(.layout)          // within 5 s: waits
        #expect(file.load().day(at: clock).correctionTotal == 1)
        recorder.flush()                            // quit
        #expect(file.load().day(at: clock).correctionTotal == 2)
    }

    @Test func eraseRemovesCountersAndFile() {
        let file = tempFile()
        let recorder = UsageRecorder(file: file, interval: 0) { true }
        recorder.recordCorrection(.layout)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        recorder.erase()
        #expect(recorder.stats.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func turningOffStopsCounting() {
        let file = tempFile()
        defer { file.erase() }
        var on = true
        let recorder = UsageRecorder(file: file, interval: 0) { on }
        recorder.recordCorrection(.layout)
        on = false
        recorder.recordCorrection(.layout)
        #expect(recorder.stats.day(at: Date()).correctionTotal == 1)
    }

    @Test func offDoesNotReadAnOldFile() throws {
        let file = tempFile()
        defer { file.erase() }
        var stats = UsageStats()
        stats.recordCorrection(.yo, at: Date())
        try file.save(stats)
        #expect(UsageRecorder(file: file) { false }.stats.isEmpty)
        #expect(!UsageRecorder(file: file) { true }.stats.isEmpty)
    }
}
