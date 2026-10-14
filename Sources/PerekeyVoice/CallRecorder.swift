// SPDX-License-Identifier: GPL-3.0-or-later

import CoreAudio
import Foundation
import os
import PerekeyVoiceCore

/// The microphone of a call: `AudioCapture` in the app, a fake in tests.
public protocol MicSource: Sendable {
    func subscribe(_ sink: any AudioSink) async throws -> AudioSubscription
    func unsubscribe(_ token: AudioSubscription) async
    /// The microphone of the settings stays as it is while a call is
    /// recorded; a choice made meanwhile applies on `release`.
    func hold() async
    func release() async
}

extension AudioCapture: MicSource {
    public func hold() {
        holdMicrophone()
    }

    public func release() {
        releaseMicrophone()
    }
}

/// The system audio of a call: `SystemAudioTap` in the app, a fake in tests.
/// Its first start may hang while macOS asks for "System Audio Recording",
/// and so may a stop meanwhile: the recorder never waits for it where
/// «Стоп» and «Пауза» have to go through.
public protocol TapSource: AnyObject, Sendable {
    func start(_ sink: any AudioSink) async throws
    func stop() async
}

@available(macOS 14.2, *)
extension SystemAudioTap: TapSource {}

/// Makes the tap of a source; its events come on the tap's queue.
public typealias TapMaker = @Sendable (SystemAudioSource, @escaping @Sendable (SystemAudioEvent) -> Void)
    -> any TapSource

/// Records a call: the microphone and the system audio as two tracks on one
/// time scale, in segments on disk, into `Recordings/<id>/`.
///
/// The microphone is a subscriber of `AudioCapture`, so dictation goes on
/// during a call; the system audio comes from a process tap read through a
/// private aggregate of its own. Each block of both carries its `mHostTime`,
/// and the scale is host time from the start minus the pauses
/// (`CallTimeline`).
///
/// A device change does not stop the recording: the track gets a gap and
/// goes on in a new segment. «Стоп» always goes through: the tap's start
/// runs off this actor, and a start still hanging when the recording stops
/// is let go once it returns.
public actor CallRecorder {
    public enum Source: Sendable, Equatable {
        /// One program and its helper processes.
        case app(bundleID: String, name: String)
        /// All the system audio but Perekey's.
        case system

        var tap: SystemAudioSource {
            switch self {
            case let .app(bundleID, _): .app(bundleID: bundleID)
            case .system: .system
            }
        }

        var meta: RecordingMeta.Source {
            switch self {
            case let .app(bundleID, name): .app(bundleID: bundleID, name: name)
            case .system: .system
            }
        }
    }

    public struct Options: Sendable, Equatable {
        public var source: Source
        public var retention: RecordingMeta.AudioRetention
        /// The user's Time Machine choice for `Recordings/`.
        public var excludedFromBackup: Bool
        /// What the queue transcribes it with after «Стоп».
        public var model: String
        /// Split «Собеседники» by voice.
        public var diarize: Bool

        public init(source: Source, retention: RecordingMeta.AudioRetention, excludedFromBackup: Bool = true,
                    model: String, diarize: Bool)
        {
            self.source = source
            self.retention = retention
            self.excludedFromBackup = excludedFromBackup
            self.model = model
            self.diarize = diarize
        }
    }

    public enum StartError: Error, Equatable {
        case alreadyRecording
        /// «Стоп» came while the recording started.
        case cancelled
        /// Bytes free where the recordings go, under `minFreeBytes`.
        case lowDiskSpace(Int64)
        case microphone(String)
        case folder(String)
    }

    public enum StopReason: String, Sendable, Equatable {
        case user
        /// 4 hours on the scale.
        case limit
        /// The Mac goes to sleep, the lid closed.
        case sleep
        /// Another user took the screen.
        case userSwitch
        /// Perekey quits: ⌘Q, logout, an update's relaunch.
        case quit
    }

    /// How the system audio track goes.
    public enum SystemAudio: Sendable, Equatable {
        case starting
        /// The tap's start has not returned for a while: macOS is likely
        /// asking for the permission.
        case waitingForPermission
        case running
        /// Only zeros while the source plays: the permission is likely off.
        case silent
        case notPermitted
        case failed(String)
    }

    public struct Status: Sendable, Equatable {
        public enum Phase: Sendable, Equatable {
            case idle, recording, paused
        }

        public var phase: Phase = .idle
        public var recording: UUID?
        public var source: Source?
        public var timeline: CallTimeline?
        public var systemAudio: SystemAudio = .starting
        /// Counts device changes on either track: each one shows
        /// «Устройство сменилось».
        public var deviceChanges = 0
        /// Why the last recording stopped.
        public var lastStop: StopReason?

        public init() {}

        /// Seconds on the recording's scale at a host time.
        public func elapsed(at hostTime: UInt64) -> Double {
            timeline?.offset(of: hostTime) ?? 0
        }
    }

    public struct Configuration: Sendable {
        public var segmentSeconds = CallRecordingLimits.segmentSeconds
        public var maxDuration = CallRecordingLimits.maxDuration
        public var minFreeBytes = CallRecordingLimits.minFreeBytes
        /// How long the tap's start may take before the panel says macOS asks.
        public var tapStartPatience: Duration = .seconds(10)
        /// How long «Стоп» waits for the tap to hand over its last block.
        public var tapStopPatience: Duration = .seconds(2)
        /// Between tries to get the microphone back after it failed.
        public var microphoneRetry: Duration = .seconds(2)
        /// How often the limit is checked.
        public var tick: Duration = .seconds(1)

        public init() {}
    }

    private let folder: RecordingsFolder
    private let mic: any MicSource
    private let makeTap: TapMaker
    private let configuration: Configuration
    private let freeSpace: @Sendable (URL) -> Int64?
    private let hostTime: @Sendable () -> UInt64
    private let onStatus: @Sendable (Status) -> Void
    private var transcriber: @Sendable () async -> (any FileTranscribing)? = { nil }
    private static let log = Logger(subsystem: "app.perekey", category: "call-recorder")

    private final class Session: @unchecked Sendable {
        let generation: Int
        let id: UUID
        let options: Options
        let log: CallLog
        let mic: SegmentWriter
        let sys: SegmentWriter
        var micToken: AudioSubscription?
        var tap: (any TapSource)?
        var tapRunning = false
        var stopping = false
        var activity: (any NSObjectProtocol)?
        var ticker: Task<Void, Never>?

        init(generation: Int, id: UUID, options: Options, log: CallLog, mic: SegmentWriter, sys: SegmentWriter) {
            self.generation = generation
            self.id = id
            self.options = options
            self.log = log
            self.mic = mic
            self.sys = sys
        }
    }

    private var session: Session?
    /// The stop under way: a second stop (⌘Q during «Стоп») waits for it.
    private var stopping: Task<UUID?, Never>?
    private var starting = false
    /// «Стоп» during `start`: it ends there, with nothing kept.
    private var startCancelled = false
    private var generation = 0
    public private(set) var status = Status()

    /// The levels of the two tracks, for the panel: read from any thread.
    public nonisolated let meters = Meters()

    public final class Meters: Sendable {
        private let writers = OSAllocatedUnfairLock<(mic: TrackMeter?, sys: TrackMeter?)>(initialState: (nil, nil))

        public var mic: Float { writers.withLock { $0.mic }?.level ?? 0 }
        public var sys: Float { writers.withLock { $0.sys }?.level ?? 0 }

        func set(mic: TrackMeter?, sys: TrackMeter?) {
            writers.withLock { $0 = (mic, sys) }
        }
    }

    public init(folder: RecordingsFolder = RecordingsFolder(), mic: any MicSource, makeTap: @escaping TapMaker,
                configuration: Configuration = Configuration(),
                freeSpace: @escaping @Sendable (URL) -> Int64? = CallRecordings.freeSpace(at:),
                hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
                onStatus: @escaping @Sendable (Status) -> Void = { _ in })
    {
        self.folder = folder
        self.mic = mic
        self.makeTap = makeTap
        self.configuration = configuration
        self.freeSpace = freeSpace
        self.hostTime = hostTime
        self.onStatus = onStatus
    }

    /// The system tap where macOS has it (14.2+).
    public static let systemTap: TapMaker = { source, onEvent in
        if #available(macOS 14.2, *) {
            SystemAudioTap(source: source, onEvent: onEvent)
        } else {
            NoTap()
        }
    }

    /// Where a stopped call goes: the file queue there is at the stop, if any.
    public func setTranscriber(_ transcriber: @escaping @Sendable () async -> (any FileTranscribing)?) {
        self.transcriber = transcriber
    }

    public var isRecording: Bool { session != nil || starting }
    public var recording: UUID? { session?.id }

    /// The recording being written, from its folder's creation until
    /// `meta.json` says `stopped`: the one «Удалить» and the audio's term
    /// leave alone. Nil otherwise. Any thread.
    public nonisolated var liveRecording: UUID? { live.withLock { $0 } }
    private nonisolated let live = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    // MARK: Start

    /// Starts a recording: checks the room on disk, makes the folder, takes
    /// the microphone, and sets the tap going without waiting for it.
    @discardableResult
    public func start(_ options: Options) async throws -> UUID {
        guard session == nil, stopping == nil, !starting else { throw StartError.alreadyRecording }
        starting = true
        startCancelled = false
        defer { starting = false }
        if let free = freeSpace(folder.root), free < configuration.minFreeBytes {
            throw StartError.lowDiskSpace(free)
        }
        let start = hostTime()
        let id: UUID
        do {
            id = try folder.create(.call(source: options.source.meta, startHostTime: start,
                                         audioRetention: options.retention),
                                   excludedFromBackup: options.excludedFromBackup)
        } catch {
            throw StartError.folder(Self.describe(error))
        }
        live.withLock { $0 = id }
        generation += 1
        let generation = generation
        let log = CallLog(folder: folder, id: id,
                          timeline: CallTimeline(startHostTime: start, ticksPerSecond: HostTime.ticksPerSecond))
        let micWriter = SegmentWriter(
            track: .mic, log: log, segmentSeconds: configuration.segmentSeconds,
            onInterrupted: { [weak self] reason in
                Task { await self?.microphoneInterrupted(reason, generation: generation) }
            })
        let sysWriter = SegmentWriter(
            track: .sys, log: log, segmentSeconds: configuration.segmentSeconds,
            onInterrupted: { [weak self] _ in
                Task { await self?.deviceChanged(generation: generation) }
            })
        await mic.hold()
        let token: AudioSubscription
        do {
            token = try await mic.subscribe(micWriter)
        } catch {
            await mic.release()
            try? folder.remove(id)
            live.withLock { $0 = nil }
            throw StartError.microphone(Self.describe(error))
        }
        guard !startCancelled else {
            await mic.unsubscribe(token)
            await mic.release()
            try? folder.remove(id)
            live.withLock { $0 = nil }
            throw StartError.cancelled
        }
        let session = Session(generation: generation, id: id, options: options, log: log, mic: micWriter,
                              sys: sysWriter)
        session.micToken = token
        session.activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Recording a call")
        self.session = session
        meters.set(mic: micWriter.meter, sys: sysWriter.meter)
        status = Status()
        status.phase = .recording
        status.recording = id
        status.source = options.source
        status.timeline = log.timeline
        status.systemAudio = .starting
        publish()
        startTap(session)
        session.ticker = Task { [weak self, tick = configuration.tick] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                await self?.tick()
            }
        }
        Self.log.info("recording started")
        return id
    }

    private func startTap(_ session: Session) {
        let generation = session.generation
        let tap = makeTap(session.options.source.tap) { [weak self] event in
            Task { await self?.tapEvent(event, generation: generation) }
        }
        session.tap = tap
        let sink = session.sys
        // On the tap's own executor: this actor stays free while it runs.
        let attempt = Task.detached { () -> Result<Void, any Error> in
            do {
                try await tap.start(sink)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        Task { [weak self, patience = configuration.tapStartPatience] in
            try? await Task.sleep(for: patience)
            await self?.tapIsSlow(generation: generation)
        }
        Task { [weak self] in
            let result = await attempt.value
            guard let self else {
                await tap.stop()
                return
            }
            await self.tapStarted(result, tap: tap, generation: generation)
        }
    }

    private func tapIsSlow(generation: Int) {
        guard let session, session.generation == generation, !session.stopping,
              status.systemAudio == .starting
        else { return }
        status.systemAudio = .waitingForPermission
        publish()
    }

    private func tapStarted(_ result: Result<Void, any Error>, tap: any TapSource, generation: Int) async {
        guard let session, session.generation == generation, !session.stopping, session.tap === tap else {
            // The recording stopped while the start hung: the tap goes now.
            if case .success = result {
                Task.detached { await tap.stop() }
            }
            return
        }
        switch result {
        case .success:
            session.tapRunning = true
            if status.systemAudio == .starting || status.systemAudio == .waitingForPermission {
                status.systemAudio = .running
            }
        case let .failure(error):
            if case .notPermitted = error as? SystemAudioTapError {
                status.systemAudio = .notPermitted
                session.sys.interrupt(.permissionDenied, at: hostTime())
            } else {
                status.systemAudio = .failed(Self.describe(error))
            }
            Self.log.error("system audio did not start: \(Self.describe(error), privacy: .public)")
        }
        publish()
    }

    private func tapEvent(_ event: SystemAudioEvent, generation: Int) {
        guard let session, session.generation == generation, !session.stopping else { return }
        switch event {
        case .processes:
            return
        case .rebuilt:
            // The writer logged the gap as the tap stopped for the rebuild.
            status.deviceChanges += 1
        case .silent:
            status.systemAudio = .silent
            session.sys.interrupt(.permissionDenied, at: hostTime())
        case .sound:
            if status.systemAudio == .silent { status.systemAudio = .running }
        case let .failed(message):
            status.systemAudio = .failed(message)
        }
        publish()
    }

    // MARK: Microphone

    private func microphoneInterrupted(_ reason: AudioCaptureInterruption, generation: Int) {
        guard let session, session.generation == generation, !session.stopping else { return }
        status.deviceChanges += 1
        publish()
        guard case .failed = reason else { return }
        // `AudioCapture` dropped its subscribers: ask again until it starts.
        session.micToken = nil
        Task { [weak self] in await self?.resubscribe(generation: generation) }
    }

    private func deviceChanged(generation: Int) {
        guard let session, session.generation == generation, !session.stopping else { return }
        status.deviceChanges += 1
        publish()
    }

    private func resubscribe(generation: Int) async {
        while let session, session.generation == generation, !session.stopping, session.micToken == nil {
            try? await Task.sleep(for: configuration.microphoneRetry)
            guard self.session === session, !session.stopping else { return }
            if let token = try? await mic.subscribe(session.mic) {
                if self.session === session, !session.stopping {
                    session.micToken = token
                } else {
                    await mic.unsubscribe(token)
                }
            }
        }
    }

    // MARK: Pause and stop

    /// Both tracks stop together; the scale stands still until `resume`.
    public func pause() {
        guard let session, !session.stopping, status.phase == .recording else { return }
        let now = hostTime()
        session.mic.pause()
        session.sys.pause()
        session.log.pause(at: now)
        let offset = session.log.offset(of: now)
        try? session.log.update { meta in
            meta.gaps.append(.init(track: .mic, startOffset: offset, reason: .paused))
            meta.gaps.append(.init(track: .sys, startOffset: offset, reason: .paused))
        }
        status.phase = .paused
        status.timeline = session.log.timeline
        publish()
    }

    public func resume() {
        guard let session, !session.stopping, status.phase == .paused else { return }
        let now = hostTime()
        session.log.resume(at: now)
        session.mic.resume(from: now)
        session.sys.resume(from: now)
        status.phase = .recording
        status.timeline = session.log.timeline
        publish()
    }

    /// Ends the recording: the open segments close, `meta.json` turns
    /// `stopped` with the job to transcribe it, and the queue gets it.
    /// Returns its id, or nil if nothing was recorded.
    @discardableResult
    public func stop(_ reason: StopReason = .user) async -> UUID? {
        if let stopping { return await stopping.value }
        guard let session else {
            if starting { startCancelled = true }
            return nil
        }
        let task = Task { await finish(session, reason) }
        stopping = task
        let id = await task.value
        stopping = nil
        return id
    }

    private func finish(_ session: Session, _ reason: StopReason) async -> UUID? {
        session.stopping = true
        session.ticker?.cancel()
        let end = hostTime()
        let duration = session.log.offset(of: end)
        // The microphone's owner never waits for the tap.
        if let token = session.micToken {
            await mic.unsubscribe(token)
        }
        session.mic.finish()
        await mic.release()
        if let tap = session.tap, session.tapRunning {
            // The tap hands over its last block as it stops, unless its stop
            // hangs: then the track ends without it.
            let stopped = await waitAtMost(configuration.tapStopPatience) { await tap.stop() }
            if !stopped { Self.log.error("the tap did not stop in time") }
        }
        session.sys.finish()
        if let activity = session.activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        self.session = nil
        meters.set(mic: nil, sys: nil)
        status.phase = .idle
        status.recording = nil
        status.lastStop = reason
        status.timeline = nil
        let job = TranscriptionJob(recording: session.id, model: session.options.model,
                                   diarize: session.options.diarize)
        var kept = true
        do {
            let meta = try folder.updateMeta(session.id) { meta in
                meta.state = .stopped
                meta.duration = duration
                if !meta.segments.isEmpty { meta.pendingJob = job }
            }
            kept = !meta.segments.isEmpty
        } catch {
            Self.log.error("meta.json at the stop: \(Self.describe(error), privacy: .public)")
        }
        if !kept {
            // Nothing reached the disk: no empty recording in the list.
            try? folder.remove(session.id)
        }
        // Only now, with meta.json stopped or the folder gone.
        live.withLock { $0 = nil }
        publish()
        Self.log.info("recording stopped: \(reason.rawValue, privacy: .public)")
        guard kept else { return nil }
        // Read now: the app's queue is made anew each time voice turns on.
        // With none, meta.json keeps the job for the queue to find.
        if let queue = await transcriber() {
            await queue.enqueue(job)
        }
        return session.id
    }

    /// Checks the limit; the ticker calls it every second.
    func tick() async {
        guard let session, !session.stopping, status.phase == .recording else { return }
        if session.log.offset(of: hostTime()) >= configuration.maxDuration {
            await stop(.limit)
        }
    }

    private func publish() {
        onStatus(status)
    }

    /// No paths: they hold the user's name.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SystemAudioTapError: error.description
        case let error as AudioCaptureError: "\(error)"
        case let error as RecordingsFolder.FileError: "\(error)"
        default: "\((error as NSError).domain) \((error as NSError).code)"
        }
    }
}

/// `meta.json` of the recording and its scale, shared by the two writers.
final class CallLog: RecordingLog {
    let folder: RecordingsFolder
    let id: UUID
    let directory: URL
    private let state: OSAllocatedUnfairLock<CallTimeline>

    init(folder: RecordingsFolder, id: UUID, timeline: CallTimeline) {
        self.folder = folder
        self.id = id
        directory = folder.directory(for: id)
        state = OSAllocatedUnfairLock(initialState: timeline)
    }

    var timeline: CallTimeline { state.withLock { $0 } }

    func offset(of hostTime: UInt64) -> Double {
        state.withLock { $0.offset(of: hostTime) }
    }

    func pause(at hostTime: UInt64) {
        state.withLock { _ = $0.pause(at: hostTime) }
    }

    func resume(at hostTime: UInt64) {
        state.withLock { _ = $0.resume(at: hostTime) }
    }

    func update(_ change: (inout RecordingMeta) -> Void) throws {
        try folder.updateMeta(id) { change(&$0) }
    }
}

/// No tap before macOS 14.2: the call has the microphone only.
private final class NoTap: TapSource {
    func start(_: any AudioSink) async throws {
        throw SystemAudioTapError.tap(kAudioHardwareUnsupportedOperationError)
    }

    func stop() async {}
}

/// Runs `work` and returns true if it ended within `limit`; else returns
/// false and lets it run on. Unlike a task group, it does not wait for a
/// child that hangs.
func waitAtMost(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
    let task = Task.detached { await work() }
    let once = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { continuation in
        let resume: @Sendable (Bool) -> Void = { value in
            let first = once.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        Task.detached {
            await task.value
            resume(true)
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            resume(false)
        }
    }
}
