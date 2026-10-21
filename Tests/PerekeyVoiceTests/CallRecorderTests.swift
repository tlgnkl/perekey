// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// The recorder with a fake microphone, a fake tap and a host clock the test
/// moves: no device, no permission, no real time.
@Suite struct CallRecorderTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "perekey-call-\(UUID().uuidString)", directoryHint: .isDirectory)
    var folder: RecordingsFolder { RecordingsFolder(root: root) }
    let clock = FakeClock()

    func recorder(tap: FakeTap = FakeTap(), mic: FakeMic = FakeMic(), free: Int64? = 50_000_000_000,
                  status: StatusLog? = nil,
                  configure: (inout CallRecorder.Configuration) -> Void = { _ in }) -> CallRecorder
    {
        var configuration = CallRecorder.Configuration()
        configuration.segmentSeconds = 1
        configuration.tick = .seconds(3600)
        configure(&configuration)
        let clock = clock
        return CallRecorder(folder: folder, mic: mic, makeTap: { _, onEvent in
            tap.onEvent = onEvent
            return tap
        }, configuration: configuration, freeSpace: { _ in free }, hostTime: { clock.now },
        onStatus: { status?.append($0) })
    }

    static let options = CallRecorder.Options(source: .app(bundleID: "us.zoom.xos", name: "zoom.us"),
                                              retention: .always, model: "parakeet-tdt-v3", diarize: true)

    private func load(_ id: UUID) throws -> RecordingMeta {
        guard case let .loaded(meta) = folder.meta(id) else { throw Failure.noMeta }
        return meta
    }

    enum Failure: Error { case noMeta }

    // MARK: Time scale

    @Test func pauseStopsTheScaleOnBothTracks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let tap = FakeTap()
        let recorder = recorder(tap: tap, mic: mic)
        let id = try await recorder.start(Self.options)
        try await tap.started()
        feedBlocks([mic.sink, tap.sink], seconds: 0.5, clock: clock)
        await recorder.pause()
        clock.advance(3) // the pause lasts 3 s
        mic.feed(seconds: 0.2, clock: clock) // dropped: paused
        await recorder.resume()
        feedBlocks([mic.sink, tap.sink], seconds: 0.5, clock: clock)
        await recorder.stop()

        let meta = try load(id)
        #expect(meta.state == .stopped)
        let mics = meta.segments.filter { $0.track == .mic }
        #expect(mics.map(\.frames) == [8000, 8000])
        #expect(abs(mics[0].startOffset) < 0.001)
        // After the pause the scale goes on from where it stood, not 3 s later.
        #expect(abs(mics[1].startOffset - 0.5) < 0.01)
        #expect(meta.segments.filter { $0.track == .sys }.count == 2)
        #expect(meta.gaps.filter { $0.reason == .paused }.map(\.track).sorted { $0.rawValue < $1.rawValue }
            == [.mic, .sys])
        #expect(abs((meta.duration ?? 0) - 1.0) < 0.01)
    }

    @Test func segmentsRotateAndMetaIsWrittenAtEach() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic)
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 1.2, clock: clock)
        // The first segment closed at 1 s: meta.json on disk soon says so,
        // written off the audio thread.
        try await waitUntil { (try? self.load(id).segments.count) == 2 }
        var meta = try load(id)
        #expect(meta.state == .recording)
        #expect(meta.segments.map(\.file) == ["mic-0001.aac", "mic-0002.aac"])
        #expect(meta.segments[0].closed && meta.segments[0].frames == 16_000)
        #expect(!meta.segments[1].closed)
        mic.feed(seconds: 1.0, clock: clock)
        await recorder.stop()
        meta = try load(id)
        #expect(meta.segments.map(\.frames) == [16_000, 16_000, 3_200])
        #expect(meta.segments.allSatisfy { $0.closed })
        for segment in meta.segments {
            let file = try AVAudioFile(forReading: folder.directory(for: id).appending(path: segment.file))
            #expect(file.fileFormat.sampleRate == 16_000)
        }
    }

    @Test func deviceChangeIsAGapNotAStop() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let tap = FakeTap()
        let status = StatusLog()
        let recorder = recorder(tap: tap, mic: mic, status: status)
        let id = try await recorder.start(Self.options)
        try await tap.started()
        tap.feed(seconds: 0.3, clock: clock)
        tap.interrupt(.deviceChanged) // headphones in: the tap is built again
        clock.advance(0.1)
        tap.feed(seconds: 0.3, clock: clock)
        mic.feed(seconds: 0.3, clock: clock)
        mic.interrupt(.configurationChange)
        mic.feed(seconds: 0.3, clock: clock)
        try await waitUntil { status.last?.deviceChanges == 2 }
        #expect(await recorder.isRecording)
        await recorder.stop()

        let meta = try load(id)
        #expect(meta.gaps.filter { $0.reason == .deviceChanged }.count == 2)
        let sys = meta.segments.filter { $0.track == .sys }
        #expect(sys.count == 2)
        #expect(abs(sys[1].startOffset - 0.4) < 0.01)
    }

    @Test func microphoneComesBackAfterItFailed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic) { $0.microphoneRetry = .milliseconds(10) }
        _ = try await recorder.start(Self.options)
        // As `AudioCapture` fails: the subscribers hear why and are dropped.
        let sink = mic.sink
        mic.drop()
        sink?.captureInterrupted(.failed("engine"))
        try await waitUntil { mic.subscriptions == 2 }
        #expect(mic.sink != nil)
        await recorder.stop()
    }

    // MARK: Start and stop

    @Test func stopGoesThroughWhileTheTapStartHangs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tap = FakeTap(start: .hang)
        let status = StatusLog()
        let recorder = recorder(tap: tap, status: status) { $0.tapStartPatience = .milliseconds(50) }
        let id = try await recorder.start(Self.options)
        try await waitUntil { status.last?.systemAudio == .waitingForPermission }
        // The start hangs until `release`: a stop that returns at all went past it.
        let stopped = await recorder.stop()
        #expect(tap.stops == 0)
        #expect(stopped == nil) // nothing was recorded: no empty recording stays
        #expect(folder.meta(id).isMissing)
        #expect(await !recorder.isRecording)
        // The hung start returns at last: the tap is let go.
        tap.release()
        try await waitUntil { tap.stops == 1 }
    }

    @Test func stopDoesNotWaitLongForAHungTapStop() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let tap = FakeTap(stop: .hang)
        let status = StatusLog()
        let recorder = recorder(tap: tap, mic: mic, status: status) { $0.tapStopPatience = .milliseconds(100) }
        let id = try await recorder.start(Self.options)
        try await waitUntil { status.last?.systemAudio == .running }
        mic.feed(seconds: 0.2, clock: clock)
        // The tap's stop hangs until `release`: the recorder's stop returns without it.
        #expect(await recorder.stop() == id)
        #expect(tap.stops == 0)
        #expect(try load(id).state == .stopped)
        tap.release()
    }

    @Test func aDeniedTapLeavesAGapAndTheMicrophoneRecords() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let tap = FakeTap(start: .fail(.notPermitted("tap")))
        let status = StatusLog()
        let recorder = recorder(tap: tap, mic: mic, status: status)
        let id = try await recorder.start(Self.options)
        try await waitUntil { status.last?.systemAudio == .notPermitted }
        mic.feed(seconds: 0.3, clock: clock)
        await recorder.stop()
        let meta = try load(id)
        #expect(meta.gaps.contains { $0.track == .sys && $0.reason == .permissionDenied })
        #expect(meta.segments.map(\.track) == [.mic])
    }

    @Test func zerosWhileTheSourcePlaysAskForThePermission() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tap = FakeTap()
        let status = StatusLog()
        let recorder = recorder(tap: tap, status: status)
        _ = try await recorder.start(Self.options)
        try await tap.started()
        tap.onEvent?(.silent(seconds: 11))
        try await waitUntil { status.last?.systemAudio == .silent }
        tap.onEvent?(.sound)
        try await waitUntil { status.last?.systemAudio == .running }
        await recorder.stop()
    }

    @Test func stopQueuesTheTranscription() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let queue = FakeQueue()
        let recorder = recorder(mic: mic)
        // The queue is read at the stop: the one there then gets the job.
        let first = FakeQueue()
        let current = OSAllocatedUnfairLock<FakeQueue?>(initialState: first)
        await recorder.setTranscriber { current.withLock { $0 } }
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 0.3, clock: clock)
        current.withLock { $0 = queue } // voice went off and on again
        await recorder.stop()
        let job = TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: true)
        #expect(queue.jobs == [job])
        #expect(first.jobs.isEmpty)
        #expect(try load(id).pendingJob == job)
        #expect(mic.holds == 0)
    }

    @Test func noStartBelowTwoGigabytes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = recorder(free: 1_500_000_000)
        await #expect(throws: CallRecorder.StartError.lowDiskSpace(1_500_000_000)) {
            try await recorder.start(Self.options)
        }
        #expect(folder.recordings().isEmpty)
        #expect(await !recorder.isRecording)
    }

    @Test func stopsAtFourHours() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let status = StatusLog()
        let recorder = recorder(mic: mic, status: status)
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 0.5, clock: clock)
        clock.advance(CallRecordingLimits.maxDuration - 10)
        await recorder.tick()
        #expect(await recorder.isRecording)
        clock.advance(10)
        await recorder.tick()
        #expect(await !recorder.isRecording)
        #expect(status.last?.lastStop == .limit)
        #expect(try load(id).state == .stopped)
    }

    @Test func aSecondStopWaitsForTheFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let tap = FakeTap(stop: .hang)
        let status = StatusLog()
        let recorder = recorder(tap: tap, mic: mic, status: status) { $0.tapStopPatience = .milliseconds(200) }
        let id = try await recorder.start(Self.options)
        try await waitUntil { status.last?.systemAudio == .running }
        mic.feed(seconds: 0.2, clock: clock)
        // «Стоп», then ⌘Q while the first stop waits for the tap.
        async let first = recorder.stop(.user)
        try await Task.sleep(for: .milliseconds(20))
        let second = await recorder.stop(.quit)
        #expect(second == id)
        #expect(try load(id).state == .stopped) // written before the quit's answer
        #expect(await first == id)
        tap.release()
    }

    @Test func aRecordingCutOffBeforeItsFirstBlockIsDropped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try folder.create(.call(source: .system, startHostTime: 1, audioRetention: .always),
                                   excludedFromBackup: true)
        #expect(CallRecordings.recoverInterrupted(in: folder).isEmpty)
        #expect(folder.meta(id).isMissing)
    }

    @Test func aJumpInHostTimeStartsANewSegment() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic) { $0.segmentSeconds = 60 }
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 0.5, clock: clock)
        clock.advance(0.03) // within 50 ms: the same segment
        mic.feed(seconds: 0.3, clock: clock)
        clock.advance(0.2) // blocks lost
        mic.feed(seconds: 0.3, clock: clock)
        await recorder.stop()
        let meta = try load(id)
        #expect(meta.segments.map(\.frames) == [12_800, 4_800])
        #expect(abs(meta.segments[1].startOffset - 1.03) < 0.005)
        let gap = try #require(meta.gaps.first)
        #expect(gap.reason == .discontinuity)
        // Where the segment's samples ran out: 0.8 s of them, the 30 ms inside the leeway.
        #expect(abs(gap.startOffset - 0.8) < 0.005)
    }

    @Test func stopDuringTheStartCancelsIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic(hangsSubscribe: true)
        let recorder = recorder(mic: mic)
        let start = Task { try await recorder.start(Self.options) }
        try await waitUntil { mic.waiting }
        #expect(await recorder.stop() == nil)
        mic.releaseSubscribe()
        await #expect(throws: CallRecorder.StartError.cancelled) { try await start.value }
        #expect(await !recorder.isRecording)
        #expect(folder.recordings().isEmpty)
        #expect(mic.sink == nil)
        #expect(mic.holds == 0)
        #expect(recorder.liveRecording == nil)
    }

    @Test func nothingIsLiveOnceStopped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let status = StatusLog()
        let recorder = recorder(mic: mic, status: status)
        let id = try await recorder.start(Self.options)
        #expect(recorder.liveRecording == id)
        #expect(status.last?.recording == id)
        mic.feed(seconds: 0.3, clock: clock)
        await recorder.stop()
        #expect(recorder.liveRecording == nil)
        #expect(status.last?.recording == nil)
    }

    @Test func deleteAllTakesTheRecordingJustStopped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic)
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 0.3, clock: clock)
        let library = TranscriptsLibrary(folder: folder, queue: nil)
        // While it records, «Удалить все» leaves it.
        #expect(await library.deleteAll(live: Set([recorder.liveRecording].compactMap { $0 })) == 0)
        #expect(folder.recordings() == [id])
        await recorder.stop()
        #expect(await library.deleteAll(live: Set([recorder.liveRecording].compactMap { $0 })) == 0)
        #expect(folder.recordings().isEmpty)
    }

    @Test func theLastCallsAudioGoesOnceTranscribed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic)
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 0.3, clock: clock)
        await recorder.stop()
        // As the queue leaves it.
        try folder.updateMeta(id) { meta in
            meta.state = .done
            meta.pendingJob = nil
        }
        let policy = CallAudioPolicy(retention: .untilTranscribed, keepDisabled: false)
        #expect(CallRecordings.removeExpiredAudio(in: folder, policy: policy, except: recorder.liveRecording) == [id])
        #expect(try load(id).audioRemovedAt != nil)
    }

    @Test func aSecondStartIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = recorder()
        _ = try await recorder.start(Self.options)
        await #expect(throws: CallRecorder.StartError.alreadyRecording) {
            try await recorder.start(Self.options)
        }
        await recorder.stop()
    }

    // MARK: After a crash

    @Test func aRecordingCutOffByACrashIsFoundAndClosed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = FakeMic()
        let recorder = recorder(mic: mic)
        let id = try await recorder.start(Self.options)
        mic.feed(seconds: 1.5, clock: clock)
        await recorder.stop()
        // As a crash leaves it: still recording, the last segment open.
        try folder.updateMeta(id) { meta in
            meta.state = .recording
            meta.pendingJob = nil
            meta.duration = nil
            meta.segments[1].closed = false
            meta.segments[1].frames = 0
            // A segment opened just before the crash, with no packet in it.
            meta.segments.append(.init(track: .sys, file: "sys-0001.aac", startHostTime: 1, startOffset: 1.4))
        }
        FileManager.default.createFile(atPath: folder.directory(for: id).appending(path: "sys-0001.aac").path,
                                       contents: Data())

        #expect(CallRecordings.recoverInterrupted(in: folder) == [id])
        let meta = try load(id)
        #expect(meta.state == .stopped)
        #expect(meta.segments.map(\.file) == ["mic-0001.aac", "mic-0002.aac"])
        #expect(!meta.segments[1].closed) // read to its end
        #expect(abs((meta.duration ?? 0) - 1.5) < 0.2)
        #expect(meta.pendingJob == nil) // offered, not queued
        // Found once: a second launch has nothing to do.
        #expect(CallRecordings.recoverInterrupted(in: folder).isEmpty)
    }

    // MARK: Audio term

    @Test func audioGoesByTermAndByProfile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func call(_ state: RecordingMeta.State, daysAgo: Double, pending: Bool = false) throws -> UUID {
            var meta = RecordingMeta.call(source: .system, startHostTime: 1,
                                          createdAt: now.addingTimeInterval(-daysAgo * 86400), audioRetention: .always)
            meta.state = state
            meta.segments = [.init(track: .mic, file: "mic-0001.aac", startHostTime: 1, startOffset: 0, frames: 10,
                                   closed: true)]
            if pending { meta.pendingJob = TranscriptionJob(recording: UUID(), model: "m", diarize: false) }
            let id = try folder.create(meta, excludedFromBackup: true)
            FileManager.default.createFile(atPath: folder.directory(for: id).appending(path: "mic-0001.aac").path,
                                           contents: Data([1]))
            return id
        }
        let old = try call(.done, daysAgo: 31)
        let oldUntranscribed = try call(.stopped, daysAgo: 40)
        let fresh = try call(.done, daysAgo: 2)
        let queued = try call(.stopped, daysAgo: 45, pending: true)
        let live = try call(.recording, daysAgo: 50)

        #expect(CallRecordings.removeExpiredAudio(in: folder, policy: .init(retention: .always, keepDisabled: false),
                                                  now: now).isEmpty)
        let month = CallRecordings.removeExpiredAudio(in: folder, policy: .init(retention: .month, keepDisabled: false),
                                                      now: now)
        #expect(month == [old]) // not the one never transcribed
        #expect(try load(oldUntranscribed).audioRemovedAt == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.directory(for: old).appending(path: "mic-0001.aac").path))
        // meta.json keeps whole seconds.
        #expect(abs(try load(old).audioRemovedAt?.timeIntervalSince(now) ?? 99) < 1)
        // The profile removes what is transcribed, whatever the user chose.
        let profile = CallRecordings.removeExpiredAudio(in: folder, policy: .init(retention: .always, keepDisabled: true),
                                                        now: now)
        #expect(profile == [fresh])
        for id in [queued, live] {
            #expect(FileManager.default.fileExists(atPath: folder.directory(for: id).appending(path: "mic-0001.aac").path))
            #expect(try load(id).audioRemovedAt == nil)
        }
        #expect(try load(fresh).segments.count == 1) // the times stay for the transcript
    }
}

// MARK: Fakes

final class FakeClock: Sendable {
    private let ticks = OSAllocatedUnfairLock(initialState: HostTime.ticks(1000))
    var now: UInt64 { ticks.withLock { $0 } }

    func advance(_ seconds: Double) {
        ticks.withLock { $0 += HostTime.ticks(seconds) }
    }
}

/// Feeds 16 kHz blocks of 100 ms stamped with the fake clock, which they move on.
func feedBlocks(_ sinks: [(any AudioSink)?], seconds: Double, clock: FakeClock) {
    let block = [Float](repeating: 0.1, count: 1600)
    for _ in 0..<Int((seconds * 10).rounded()) {
        for sink in sinks {
            block.withUnsafeBufferPointer { sink?.receive($0, hostTime: clock.now) }
        }
        clock.advance(0.1)
    }
}

final class FakeMic: MicSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: (any AudioSink)?
    private var count = 0
    private var held = 0
    private let hangsSubscribe: Bool
    private var gate: CheckedContinuation<Void, Never>?

    init(hangsSubscribe: Bool = false) {
        self.hangsSubscribe = hangsSubscribe
    }

    /// A subscribe waits for `releaseSubscribe`.
    var waiting: Bool { lock.withLock { gate != nil } }

    func releaseSubscribe() {
        lock.withLock {
            defer { gate = nil }
            return gate
        }?.resume()
    }

    var sink: (any AudioSink)? { lock.withLock { current } }
    var subscriptions: Int { lock.withLock { count } }
    var holds: Int { lock.withLock { held } }

    func subscribe(_ sink: any AudioSink) async throws -> AudioSubscription {
        if hangsSubscribe, subscriptions == 0 {
            await withCheckedContinuation { continuation in lock.withLock { gate = continuation } }
        }
        return lock.withLock {
            current = sink
            count += 1
            return AudioSubscription(id: UInt64(count))
        }
    }

    func unsubscribe(_: AudioSubscription) async {
        lock.withLock { current = nil }
    }

    func hold() async { lock.withLock { held += 1 } }
    func release() async { lock.withLock { held -= 1 } }

    func feed(seconds: Double, clock: FakeClock) {
        feedBlocks([sink], seconds: seconds, clock: clock)
    }

    func interrupt(_ reason: AudioCaptureInterruption) {
        sink?.captureInterrupted(reason)
    }

    /// As `AudioCapture` does after `.failed`: the subscribers are gone.
    func drop() {
        lock.withLock { current = nil }
    }
}

final class FakeTap: TapSource, @unchecked Sendable {
    enum Behavior {
        case succeed
        case hang
        case fail(SystemAudioTapError)
    }

    private let lock = NSLock()
    private let startBehavior: Behavior
    private let stopBehavior: Behavior
    private var current: (any AudioSink)?
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var stopCount = 0
    private var startCount = 0
    var onEvent: (@Sendable (SystemAudioEvent) -> Void)?

    init(start: Behavior = .succeed, stop: Behavior = .succeed) {
        startBehavior = start
        stopBehavior = stop
    }

    var stops: Int { lock.withLock { stopCount } }
    var sink: (any AudioSink)? { lock.withLock { current } }

    func start(_ sink: any AudioSink) async throws {
        lock.withLock {
            startCount += 1
            current = sink
        }
        switch startBehavior {
        case .succeed: return
        case .hang: await wait()
        case let .fail(error): throw error
        }
    }

    func stop() async {
        if case .hang = stopBehavior { await wait() }
        lock.withLock {
            stopCount += 1
            current = nil
        }
    }

    /// Lets a hung start or stop return.
    func release() {
        let gate = lock.withLock {
            released = true
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    private func wait() async {
        await withCheckedContinuation { continuation in
            let go = lock.withLock {
                if released { return true }
                gate = continuation
                return false
            }
            if go { continuation.resume() }
        }
    }

    func started() async throws {
        try await waitUntil { self.lock.withLock { self.startCount > 0 } }
    }

    func feed(seconds: Double, clock: FakeClock) {
        feedBlocks([sink], seconds: seconds, clock: clock)
    }

    func interrupt(_ reason: AudioCaptureInterruption) {
        lock.withLock { current }?.captureInterrupted(reason)
    }
}

final class FakeQueue: FileTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [TranscriptionJob] = []
    var jobs: [TranscriptionJob] { lock.withLock { queued } }

    func enqueue(_ job: TranscriptionJob) async { lock.withLock { queued.append(job) } }
    func cancel(_: UUID) async {}
    func phases() -> AsyncStream<[UUID: TranscriptionPhase]> { AsyncStream { $0.finish() } }
    var isBusy: Bool { false }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [CallRecorder.Status] = []

    func append(_ status: CallRecorder.Status) {
        lock.withLock { all.append(status) }
    }

    var last: CallRecorder.Status? { lock.withLock { all.last } }
}

/// Polls until `condition` holds. It counts polls, not wall time: when other
/// tests keep the pool busy for seconds, the polls slow down with the work
/// they wait for, and a deadline in wall time would run out before that work
/// had a turn. At least 20 s on an idle machine before it gives up.
func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if await condition() { return }
    Issue.record("the condition did not come true in 2000 polls")
}

extension RecordingsFolder.Loaded {
    var isMissing: Bool {
        if case .missing = self { true } else { false }
    }
}
