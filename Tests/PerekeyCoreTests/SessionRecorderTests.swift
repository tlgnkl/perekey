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
final class RecorderHarness {
    var buffer: RecordingBuffer
    let recorder: SessionRecorder
    let directory: URL
    /// The recorder's answers, applied on the test's thread as the engine
    /// applies them on the tap thread.
    private let answers = OSAllocatedUnfairLock(initialState: [(count: Int, newDay: Bool)]())

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
        let batch = buffer.take()
        recorder.write(batch, close: close) { [answers] count, newDay in
            answers.withLock { $0.append((count, newDay)) }
        }
        settle()
    }

    /// Waits for the recorder and hands its answers to the buffer.
    func settle() {
        recorder.drain()
        for answer in answers.withLock({ list in defer { list.removeAll() }; return list }) {
            buffer.written(answer.count, newDay: answer.newDay)
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
        options.limit = 24
        options.resume = 12
        let harness = RecorderHarness(options: options)
        var desk = Desk()
        var plain = Desk()
        harness.attach(&desk)
        desk.send(.focusChanged(Desk.textEdit))
        plain.send(.focusChanged(Desk.textEdit))
        // The recorder never answers: the disk is stuck.
        var stuck: [[RecordingBuffer.Entry]] = []
        desk.watcher = { [unowned harness] event, output, machine in
            if harness.buffer.record(event, output, machine: machine) { stuck.append(harness.buffer.take()) }
        }
        desk.type("[jhjij hello ghbdtn ")
        plain.type("[jhjij hello ghbdtn ")
        #expect(desk.text == plain.text)
        let lines = stuck.joined()
        let gaps = lines.filter { if case .gap(.overflow) = $0 { true } else { false } }
        #expect(gaps.count == 1)
        #expect(lines.count + harness.buffer.entries.count <= options.limit)

        // The disk catches up: written, then a quiet point starts a segment.
        harness.attach(&desk)
        for batch in stuck {
            harness.recorder.write(batch) { _, _ in }
            harness.buffer.written(batch.count, newDay: false)
        }
        harness.recorder.drain()
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
        #expect(stride * options.limit < 4 << 20, "\(stride) bytes an entry")
        #expect(options.batch < options.resume && options.resume < options.limit)
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
}
#endif
