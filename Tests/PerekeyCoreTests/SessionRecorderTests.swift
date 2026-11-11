// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import Foundation
import os
@testable import PerekeyInput
import PerekeyModelKit
import Testing
@testable import PerekeyCore

/// The typing recorder of the app (`RecordingBuffer` on the tap thread,
/// `SessionRecorder` on its queue), driven by the test desk the way the
/// engine drives it: every event the machine handled, then the machine.
/// The files it writes are read back by `perekey-eval replay`'s reader.
extension RecordingBuffer {
    /// For tests that have the machine itself at hand: what the engine passes
    /// as two closures, so that no copy of the machine is made.
    mutating func record(_ event: InputEvent, _ output: Output, machine: InputMachine) -> Bool {
        record(event, output, quiet: { machine.isQuiet }, snapshot: { (machine.snapshot, machine.classifier) })
    }
}

final class RecorderHarness {
    var buffer: RecordingBuffer
    let recorder: SessionRecorder
    let directory: URL
    /// The recorder's answers, applied on the test's thread as the engine
    /// applies them on the tap thread.
    private let answers = OSAllocatedUnfairLock(initialState: [SessionRecorder.Written]())

    init(options: RecordingBuffer.Options = RecordingBuffer.Options(),
         excludedApps: Set<String> = RecordingBuffer.passwordManagers,
         now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_762_780_000) })
    {
        directory = FileManager.default.temporaryDirectory.appending(path: "perekey-sessions-\(UUID().uuidString)")
        buffer = RecordingBuffer(options: options, excludedApps: excludedApps)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        recorder = SessionRecorder(folder: SessionFolder(directory: directory), perekey: "0.3.0", build: "test",
                                   calendar: calendar, now: now)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Watches the desk from now on.
    func attach(_ desk: inout Desk) {
        desk.watcher = { [unowned self] event, output, machine in
            if self.buffer.record(event, output, machine: machine) { self.handOver() }
        }
    }

    /// What the engine's timer and `stopRecording` do: the entries go to the
    /// recorder, and its answers come back.
    func handOver(close: Bool = false) {
        write(buffer.take(), close: close)
    }

    /// Writes `batch` and applies the recorder's answer.
    func write(_ batch: [RecordingBuffer.Entry], close: Bool = false) {
        recorder.write(batch, close: close) { [answers] written in
            answers.withLock { $0.append(written) }
        }
        settle()
    }

    /// Waits for the recorder and hands its answers to the buffer.
    func settle() {
        recorder.drain()
        for answer in answers.withLock({ list in defer { list.removeAll() }; return list }) {
            buffer.written(answer.batch, newDay: answer.newDay, failed: answer.failed)
        }
    }

    var files: [URL] { SessionFolder(directory: directory).files() }

    func sessions() throws -> [Session] {
        try files.map { try SessionFile.read(path: $0.path) }
    }

    func bytes() throws -> Data {
        try files.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }
    }
}

extension Session {
    /// Every segment replayed exactly: nil when all match.
    func firstMismatch() -> ReplayMismatch? {
        segments.lazy.compactMap {
            SessionDriver.run($0, mode: .exact, classifier: SessionTape.classifier).mismatch
        }.first
    }

    /// When the user's keys were pressed and released: neither the keys of
    /// retypes nor the held keys that came back.
    var keyTimes: [Double] {
        segments.flatMap(\.steps).compactMap {
            if case let .key(key, time) = $0.event, key.origin == .user { time } else { nil }
        }
    }
}

@Suite struct SessionRecorderTests {
    @Test func aRecordingReplaysExactly() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        // Starts at once: right after a focus change the machine is quiet.
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("[jhjij hello ghbdtn ")
        // The hint's Undo takes the last switch back.
        let seq = try #require(desk.corrections.last?.seq)
        desk.send(.undoLastCorrection(seq: seq, time: desk.time))
        desk.type("ok vbh ")
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("hfccnjzybt ")
        harness.handOver(close: true)

        let sessions = try harness.sessions()
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.header.perekey == "0.3.0" && session.header.build == "test")
        #expect(session.segments.count == 1)
        #expect(session.segments[0].steps.count > 100)
        #expect(!session.droppedTail)
        #expect(session.firstMismatch() == nil)
        // The switches are in the file as the machine answered them.
        let switches = session.segments[0].steps.flatMap(\.output.effects).filter {
            if case .corrected = $0 { true } else { false }
        }
        #expect(switches.count == desk.corrections.count)
    }

    @Test func recordingStartsAtAQuietPoint() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        desk.type("hel")
        harness.attach(&desk)
        // In the middle of a word: no snapshot could replay from here.
        desk.type("lo world ")
        #expect(harness.buffer.entries.isEmpty)
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("ghbdtn ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(session.segments.count == 1)
        #expect(session.firstMismatch() == nil)
        // The keys before the click are not in it.
        #expect(session.keyTimes.count == 2 * "ghbdtn ".count)
    }

    /// Keys typed in a password field, under Secure Input and in a password
    /// manager never reach the file: one gap line stands for them.
    @Test(arguments: [
        (Focus(bundleID: "com.apple.Safari", isSecureField: true), SessionGap.secureField),
        (Focus(bundleID: "com.1password.1password"), SessionGap.excludedApp),
        (Focus(bundleID: "com.apple.Passwords"), SessionGap.excludedApp),
        (Focus(bundleID: "org.keepassxc.keepassxc"), SessionGap.excludedApp),
    ])
    func keysOfAPasswordNeverReachTheFile(focus: Focus, reason: SessionGap) throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        desk.send(.focusChanged(focus))
        let start = desk.time
        desk.type("ctrhtn hunter2 ")
        let end = desk.time
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("ghbdtn ")
        harness.handOver(close: true)

        let session = try #require(try harness.sessions().first)
        #expect(session.segments.count == 2)
        #expect(session.segments[0].gap == reason)
        #expect(session.keyTimes.allSatisfy { $0 <= start || $0 > end })
        #expect(session.keyTimes.count == 2 * ("hello ".count + "ghbdtn ".count))
        // Nothing of the focus change into it either: the gap is all.
        #expect(session.segments[0].steps.allSatisfy { step in
            if case let .focusChanged(recorded, _) = step.event { recorded == Desk.textEdit } else { true }
        })
        #expect(session.firstMismatch() == nil)
    }

    @Test func secureInputMakesAGap() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        desk.send(.secureInputChanged(true))
        let start = desk.time
        desk.type("hunter2")
        let end = desk.time
        desk.send(.secureInputChanged(false))
        // The next quiet point starts the segment.
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("world ")
        harness.handOver(close: true)

        let session = try #require(try harness.sessions().first)
        #expect(session.segments.map(\.gap) == [.secureInput, nil])
        #expect(session.keyTimes.allSatisfy { $0 <= start || $0 > end })
        #expect(session.firstMismatch() == nil)
    }

    @Test func anAppTheUserAddsIsNeverRecorded() throws {
        let harness = RecorderHarness(excludedApps: RecordingBuffer.passwordManagers.union(["com.example.Bank"]))
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Focus(bundleID: "com.example.Bank")))
        desk.type("secret ")
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        // Added while its app is in front: nothing more from it.
        harness.buffer.excludedApps.insert("com.apple.TextEdit")
        let start = desk.time
        desk.type("ctrhtn ")
        harness.handOver(close: true)

        let session = try #require(try harness.sessions().first)
        #expect(session.segments.count == 1)
        #expect(session.segments[0].gap == .excludedApp)
        #expect(session.keyTimes.count == 2 * "hello ".count)
        #expect(session.keyTimes.allSatisfy { $0 <= start })
        #expect(session.firstMismatch() == nil)
    }

    @Test func recordingInsideAPasswordFieldWaitsForItsEnd() throws {
        let harness = RecorderHarness()
        var desk = Desk(focus: Focus(bundleID: "com.apple.Safari", isSecureField: true))
        harness.attach(&desk)
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("hunter2 ")
        #expect(harness.buffer.entries.isEmpty)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(session.segments.count == 1)
        #expect(session.keyTimes.count == 2 * "hello ".count)
    }

    /// The selected text of a document is recorded as "x"s only.
    @Test func selectedTextNeverReachesTheFile() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.send(.selectionRead(seq: 1, text: "пароль от банка", viaAccessibility: true))
        desk.type("hello ")
        harness.handOver(close: true)
        let text = try #require(String(data: try harness.bytes(), encoding: .utf8))
        #expect(!text.contains("пароль") && !text.contains("банка"))
        #expect(text.contains(String(repeating: "x", count: "пароль от банка".count)))
    }

    /// A full buffer stops the recording, not the typing: the machine
    /// answers the same, and the recording goes on once the disk catches up.
    @Test func overflowMakesAGapAndTypingGoesOn() throws {
        var options = RecordingBuffer.Options()
        options.batch = 8
        options.buffers = 3
        options.resume = 2
        let harness = RecorderHarness(options: options)
        var desk = Desk()
        var plain = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        plain.send(.focusChanged(Desk.textEdit))
        // The recorder never answers: the disk is stuck.
        var stuck: [[RecordingBuffer.Entry]] = []
        desk.watcher = { [unowned harness] event, output, machine in
            if harness.buffer.record(event, output, machine: machine) {
                let batch = harness.buffer.take()
                if !batch.isEmpty { stuck.append(batch) }
            }
        }
        desk.type("[jhjij hello ghbdtn ")
        plain.type("[jhjij hello ghbdtn ")
        #expect(desk.text == plain.text)
        // The gap is in the array that is full and cannot leave.
        let lines = Array(stuck.joined()) + harness.buffer.entries
        let gaps = lines.filter { if case .gap(.overflow) = $0 { true } else { false } }
        #expect(gaps.count == 1)
        #expect(lines.count <= options.buffers * options.batch)

        // The disk catches up: written, then a quiet point starts a segment.
        harness.attach(&desk)
        for batch in stuck { harness.write(batch) }
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("hello ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(session.segments.map(\.gap) == [.overflow, nil])
        #expect(session.firstMismatch() == nil)
    }

    @Test func theBufferStaysSmall() {
        let options = RecordingBuffer.Options()
        let stride = MemoryLayout<RecordingBuffer.Entry>.stride
        #expect(stride * options.batch * options.buffers < 4 << 20, "\(stride) bytes an entry")
        #expect(options.resume < options.buffers)
    }

    /// A new day starts a file at the next quiet point; each file reads alone.
    @Test func aNewDayStartsANewFile() throws {
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_762_819_000)) // 23:56 UTC
        let harness = RecorderHarness(now: { clock.withLock { $0 } })
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        harness.handOver()
        clock.withLock { $0 = $0.addingTimeInterval(600) } // 00:06
        desk.type("ghbdtn ")
        // The recorder says the day is over.
        harness.handOver()
        desk.type("world ")
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("vbh ")
        harness.handOver(close: true)

        #expect(harness.files.map(\.lastPathComponent) == ["2025-11-10-1.pksession", "2025-11-11-1.pksession"])
        let sessions = try harness.sessions()
        #expect(sessions.allSatisfy { $0.segments.count == 1 && $0.firstMismatch() == nil })
        #expect(sessions.map(\.keyTimes.count) == [2 * "hello ghbdtn world ".count, 2 * "vbh ".count])
    }

    @Test func everyLaunchStartsAFile() throws {
        let harness = RecorderHarness()
        for _ in 0..<2 {
            var desk = Desk()
            harness.buffer = RecordingBuffer()
            harness.attach(&desk)
            desk.send(.focusChanged(Desk.textEdit))
            desk.type("hello ")
            harness.handOver(close: true)
        }
        #expect(harness.files.map(\.lastPathComponent) == ["2025-11-10-1.pksession", "2025-11-10-2.pksession"])
        #expect(try harness.sessions().allSatisfy { $0.segments.count == 1 })
    }

    /// Erasing removes the files; a recording that runs starts a new one
    /// with its own snapshot, and nothing of before is in it.
    @Test func erasingStartsOver() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        harness.handOver()
        #expect(harness.files.count == 1)
        harness.recorder.eraseAll()
        harness.recorder.drain()
        #expect(harness.files.isEmpty)
        // Typed before the buffer heard of it: dropped with no file to go to.
        desk.type("world ")
        harness.handOver()
        #expect(harness.files.isEmpty)
        harness.buffer.restart()
        let start = desk.time
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("ghbdtn ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(harness.files.count == 1)
        #expect(session.keyTimes.allSatisfy { $0 > start })
        #expect(session.firstMismatch() == nil)
    }

    // MARK: - Unknown focus

    /// The focus the machine does not know — right after an app switch, or
    /// when accessibility does not answer — may be a password field: no key
    /// of it reaches the file.
    @Test func unknownFocusMakesAGapAndNoKeyIsInTheFile() throws {
        let harness = RecorderHarness()
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        desk.send(.focusChanged(.unknown(bundleID: "com.apple.Safari")))
        let start = desk.time
        desk.type("hunter2 ctrhtn ")
        let end = desk.time
        // The focus becomes known again: the recording goes on in a new segment.
        desk.send(.focusChanged(Desk.textEdit, .resolved))
        desk.type("ghbdtn ")
        harness.handOver(close: true)

        let session = try #require(try harness.sessions().first)
        #expect(session.segments.map(\.gap) == [.unknownFocus, nil])
        #expect(session.keyTimes.allSatisfy { $0 <= start || $0 > end })
        #expect(session.keyTimes.count == 2 * ("hello ".count + "ghbdtn ".count))
        #expect(session.firstMismatch() == nil)
    }

    /// A machine that has had no focus event yet has no focus at all.
    @Test func noFocusYetRecordsNothing() throws {
        let harness = RecorderHarness()
        var desk = Desk(focus: nil)
        harness.attach(&desk)
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("hunter2 ")
        #expect(harness.buffer.entries.isEmpty)
        #expect(harness.buffer.status == .waiting)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(session.segments.count == 1)
        #expect(session.keyTimes.count == 2 * "hello ".count)
    }

    // MARK: - A buffer from a pool

    /// The tap thread makes no array: the batches go back and forth between
    /// the buffer and the recorder, and the buffer never grows past its room.
    @Test func batchesComeFromAPoolAndGoBack() throws {
        var options = RecordingBuffer.Options()
        options.batch = 8
        options.buffers = 3
        options.resume = 2
        let harness = RecorderHarness(options: options)
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        let capacity = harness.buffer.entries.capacity
        #expect(capacity >= options.batch)
        for _ in 0..<12 {
            desk.type("hello ")
            #expect(harness.buffer.entries.capacity == capacity)
            #expect(harness.buffer.spareBuffers <= options.buffers - 1)
        }
        harness.handOver()
        // The recorder gave the used array back, empty and with its room.
        #expect(harness.buffer.spareBuffers == options.buffers - 1)
        #expect(harness.buffer.entries.capacity == capacity)
        harness.handOver(close: true)
        #expect(try harness.sessions().first?.firstMismatch() == nil)
    }

    /// Without a spare array a full buffer does not grow: it ends the
    /// segment with `gap(overflow)`.
    @Test func aFullBufferWithNoSpareDoesNotGrow() {
        var options = RecordingBuffer.Options()
        options.batch = 4
        options.buffers = 2
        options.resume = 1
        var buffer = RecordingBuffer(options: options)
        var desk = Desk()
        var handed: [[RecordingBuffer.Entry]] = []
        desk.watcher = { event, output, machine in
            if buffer.record(event, output, machine: machine) {
                let batch = buffer.take()
                if !batch.isEmpty { handed.append(batch) }
            }
        }
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello world ")
        #expect(handed.count == 1)
        // The gap that ends the segment is in the array that cannot leave.
        #expect(buffer.entries.contains { if case .gap(.overflow) = $0 { true } else { false } })
        #expect(buffer.entries.count <= options.batch)
        #expect(buffer.entries.capacity < 2 * options.batch)
        #expect(buffer.status == .waiting)
    }

    // MARK: - The machine is not touched

    /// Between segments the buffer asks only the cheap question; the snapshot
    /// is made when a segment opens, not on every event of a stretch of typing
    /// that is not quiet.
    @Test func theSnapshotIsMadeOnlyWhenASegmentOpens() {
        var buffer = RecordingBuffer()
        var snapshots = 0
        var quiet = false
        let output = Output()
        var machine = InputMachine()
        _ = machine.handle(.focusChanged(Desk.textEdit))
        let known = machine.snapshot
        for _ in 0..<50 {
            _ = buffer.record(.focusChanged(Desk.textEdit, .moved), output, quiet: { quiet }, snapshot: {
                snapshots += 1
                return (known, nil)
            })
        }
        #expect(snapshots == 0)
        quiet = true
        _ = buffer.record(.focusChanged(Desk.textEdit, .moved), output, quiet: { quiet }, snapshot: {
            snapshots += 1
            return (known, nil)
        })
        #expect(snapshots == 1)
        #expect(buffer.status == .recording)
        // Open: neither is asked while typing goes on (the file is started).
        for _ in 0..<20 {
            _ = buffer.record(.deadline(time: 1), output, quiet: { true }, snapshot: {
                snapshots += 1
                return (known, nil)
            })
        }
        #expect(snapshots == 1)
    }

    // MARK: - A file that cannot be written

    /// The buffer ends the segment when the recorder says the batch did not
    /// reach a file, and starts a new file at a quiet point a little later.
    @Test func aFailedWriteEndsTheSegmentAndANewFileFollows() {
        var options = RecordingBuffer.Options()
        options.retry = 5
        var buffer = RecordingBuffer(options: options)
        var desk = Desk()
        var handed: [[RecordingBuffer.Entry]] = []
        desk.watcher = { event, output, machine in
            if buffer.record(event, output, machine: machine) { handed.append(buffer.take()) }
        }
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("hello ")
        #expect(buffer.status == .recording)
        let first = buffer.take()
        // The disk is full: the batch did not reach a file.
        buffer.written(first, newDay: false, failed: true)
        #expect(buffer.status == .failed)
        let before = buffer.entries.count
        desk.type("one ")
        // Nothing is kept while it is closed, and the first retry is not yet.
        #expect(buffer.entries.count == before)
        #expect(buffer.status == .failed)
        // After the retry, at a quiet point: a snapshot that starts a file.
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("two ")
        #expect(buffer.status == .recording)
        let snapshots = buffer.entries.compactMap { entry -> Bool? in
            if case let .snapshot(_, _, newFile) = entry { newFile } else { nil }
        }
        #expect(snapshots == [true])
    }

    /// A folder that cannot be made: the file is not created, the badge says
    /// so; once the folder can be made, the next segment is in a file of its own.
    @Test func aFileThatIsNotCreatedIsToldToTheBuffer() throws {
        var options = RecordingBuffer.Options()
        options.retry = 4
        let harness = RecorderHarness(options: options)
        // A file where the folder should be.
        #expect(FileManager.default.createFile(atPath: harness.directory.path, contents: Data()))
        var desk = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        desk.type("lost ")
        harness.handOver()
        #expect(harness.buffer.status == .failed)

        try FileManager.default.removeItem(at: harness.directory)
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("hello ")
        desk.send(.click(time: desk.time, onHint: false))
        desk.type("ghbdtn ")
        harness.handOver(close: true)
        let session = try #require(try harness.sessions().first)
        #expect(harness.files.count == 1)
        #expect(session.firstMismatch() == nil)
        // What was typed while the file could not be made is not in the new one.
        #expect(session.keyTimes.count < 2 * "lost hello ghbdtn ".count)
        #expect(!session.keyTimes.isEmpty)
    }
}
#endif
