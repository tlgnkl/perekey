// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
import os
@testable import PerekeyInput
import PerekeyModelKit
import Testing
@testable import PerekeyCore

/// The engine's glue around the recording: hand-overs, the recorder's
/// answers, the status of the badge, the end of the recording. The engine
/// itself needs a tap; its timer calls `tick()` and its `perform` is the `hop`
/// here, which runs the answers when the test says.
final class PipelineHarness {
    let directory: URL
    let recorder: SessionRecorder
    /// The answers waiting to be run on the "tap thread" (the test's).
    private let hopped = OSAllocatedUnfairLock(initialState: [@Sendable (RecordingPipeline?) -> Void]())
    private(set) var statuses: [TypingRecordingStatus] = []
    /// What the engine holds as its recording.
    var current: RecordingPipeline?

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "perekey-pipeline-\(UUID().uuidString)")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        recorder = SessionRecorder(folder: SessionFolder(directory: directory), perekey: "0.3.0", build: "test",
                                   calendar: calendar, now: { Date(timeIntervalSince1970: 1_762_780_000) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func make(number: Int = 1, options: RecordingBuffer.Options = RecordingBuffer.Options()) -> RecordingPipeline {
        let pipeline = RecordingPipeline(
            recorder: recorder, excludedApps: RecordingBuffer.passwordManagers, number: number, options: options,
            hop: { [hopped] block in hopped.withLock { $0.append(block) } },
            report: { [unowned self] in statuses.append($0) }
        )
        current = pipeline
        return pipeline
    }

    /// Lets the recorder finish, then runs its answers on the test's thread.
    func deliver() {
        recorder.drain()
        let blocks = hopped.withLock { list in defer { list.removeAll() }; return list }
        for block in blocks { block(current) }
    }

    /// Feeds the desk's events to `pipeline`, as the engine's `step` does.
    func attach(_ pipeline: RecordingPipeline, to desk: inout Desk) {
        desk.watcher = { event, output, machine in
            pipeline.record(event, output, quiet: { machine.isQuiet }, snapshot: { (machine.snapshot, machine.classifier) })
        }
    }

    var files: [URL] { SessionFolder(directory: directory).files() }

    func sessions() throws -> [Session] {
        try files.map { try SessionFile.read(path: $0.path) }
    }
}

@Suite struct RecordingPipelineTests {
    /// The engine's timer, once a second, hands over what typing left; a
    /// second tick with nothing new hands over nothing.
    @Test func theTimerHandsOverAPartialBatch() throws {
        let harness = PipelineHarness()
        let pipeline = harness.make()
        var desk = Desk()
        harness.attach(pipeline, to: &desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        // Far from a full batch: nothing is written yet.
        harness.recorder.drain()
        #expect(harness.files.isEmpty)
        pipeline.tick()
        harness.deliver()
        let session = try #require(try harness.sessions().first)
        #expect(session.segments[0].steps.count > 0)
        let spare = pipeline.buffer.spareBuffers
        pipeline.tick()
        harness.deliver()
        #expect(pipeline.buffer.spareBuffers == spare)
        pipeline.stop()
        harness.deliver()
        #expect(try harness.sessions().first?.firstMismatch() == nil)
    }

    /// A full batch is handed over by the pipeline itself, and the array
    /// comes back with the answer.
    @Test func aFullBatchGoesAndItsArrayComesBack() {
        var options = RecordingBuffer.Options()
        options.batch = 16
        options.buffers = 4
        options.resume = 2
        let harness = PipelineHarness()
        let pipeline = harness.make(options: options)
        var desk = Desk()
        harness.attach(pipeline, to: &desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello world ")
        #expect(pipeline.buffer.spareBuffers < options.buffers - 1)
        harness.deliver()
        #expect(pipeline.buffer.spareBuffers == options.buffers - 1)
        pipeline.stop()
        harness.deliver()
    }

    /// An answer of an earlier recording is not for the one that runs now.
    @Test func anAnswerOfAnEarlierRecordingIsDropped() {
        var options = RecordingBuffer.Options()
        options.batch = 8
        options.buffers = 4
        options.resume = 2
        let harness = PipelineHarness()
        let first = harness.make(number: 1, options: options)
        var desk = Desk()
        harness.attach(first, to: &desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        // The user switched it off and on: the engine has a new pipeline,
        // while the first one's answers are still on their way.
        let second = harness.make(number: 2, options: options)
        let spare = second.buffer.spareBuffers
        let status = second.status
        harness.deliver()
        #expect(second.buffer.spareBuffers == spare)
        #expect(second.status == status)
        #expect(first.buffer.spareBuffers < options.buffers - 1)
    }

    /// The badge follows the recorder: waiting until a quiet point, recording
    /// in a segment, failed when the file cannot be made, recording again
    /// after a new file.
    @Test func theStatusFollowsTheRecorder() throws {
        var options = RecordingBuffer.Options()
        options.retry = 4
        let harness = PipelineHarness()
        // A file where the folder should be.
        #expect(FileManager.default.createFile(atPath: harness.directory.path, contents: Data()))
        let pipeline = harness.make(options: options)
        #expect(harness.statuses == [.waiting])
        var desk = Desk(focus: nil)
        harness.attach(pipeline, to: &desk)
        // No focus yet: the recorder waits.
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("a ")
        #expect(harness.statuses == [.waiting])
        desk.send(.focusChanged(Desk.textEdit))
        #expect(harness.statuses.last == .recording)
        desk.type("hello ")
        pipeline.tick()
        harness.deliver()
        #expect(harness.statuses.last == .failed)

        try FileManager.default.removeItem(at: harness.directory)
        for _ in 0..<3 {
            desk.send(.click(time: desk.time, onHint: false))
            desk.type("ghbdtn ")
        }
        #expect(harness.statuses.last == .recording)
        // A password field: waiting again.
        desk.send(.focusChanged(Focus(bundleID: "com.apple.Safari", isSecureField: true)))
        #expect(harness.statuses.last == .waiting)
        pipeline.stop()
        harness.deliver()
        #expect(try harness.sessions().first?.firstMismatch() == nil)
    }

    /// At quit nothing queued would still run: the call returns with the
    /// rest written and the file closed.
    @Test func finishWritesTheRestBeforeItReturns() throws {
        let harness = PipelineHarness()
        let pipeline = harness.make()
        var desk = Desk()
        harness.attach(pipeline, to: &desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ghbdtn ")
        pipeline.finish()
        // No drain, no answers: read the file at once.
        let session = try #require(try harness.sessions().first)
        #expect(!session.droppedTail)
        #expect(session.keyTimes.count == 2 * "hello ghbdtn ".count)
        #expect(session.firstMismatch() == nil)
        // The file is closed: a later write goes to a new one.
        let bytes = try Data(contentsOf: try #require(harness.files.first))
        #expect(bytes.last == 0x0A)
    }

    /// «Erase» while the recording runs: what was written is gone, what was
    /// typed before the buffer heard of it is dropped, and the recording goes
    /// on in a new file that starts with its own snapshot.
    @Test func erasingWhileRecordingStartsOver() throws {
        let harness = PipelineHarness()
        let pipeline = harness.make()
        var desk = Desk()
        harness.attach(pipeline, to: &desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        pipeline.tick()
        harness.deliver()
        #expect(harness.files.count == 1)
        // The engine: the recorder erases, then the tap thread restarts the buffer.
        harness.recorder.eraseAll()
        harness.recorder.drain()
        #expect(harness.files.isEmpty)
        pipeline.restart()
        let start = desk.time
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("ghbdtn ")
        pipeline.finish()
        let session = try #require(try harness.sessions().first)
        #expect(harness.files.count == 1)
        #expect(session.keyTimes.allSatisfy { $0 > start })
        #expect(session.keyTimes.count == 2 * "ghbdtn ".count)
        #expect(session.firstMismatch() == nil)
    }
}
#endif
