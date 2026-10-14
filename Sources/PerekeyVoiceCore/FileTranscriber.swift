// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// The queue of files and call recordings: one recording at a time, each
/// track in windows (`WindowSettings`), for every engine. Between windows it
/// yields to dictation, checks for cancel and saves what it has done in
/// `transcript.partial.json`. Then the voices of the others are split by
/// the diarizer, the tracks merged, and `transcript.json` written.
///
/// Dictation never waits for the queue: it runs at once on its own engine.
/// The queue stops at the next window's edge and goes on once the text is in.
///
/// Models load for the first job and stay until the queue is empty. The
/// queue does not log what it heard.
public actor FileTranscriber: FileTranscribing {
    public struct Environment: Sendable {
        public var folder: RecordingsFolder
        public var opener: any LongAudioOpener
        /// Finds the window's edges and skips windows without speech; without
        /// it windows end at their full length.
        public var detector: (any SpeechDetector)?
        /// The engine of a job's model; nil if it cannot run here.
        public var makeEngine: @Sendable (String) -> (any SpeechEngine)?
        public var makeDiarizer: @Sendable () -> (any DiarizerEngine)?
        public var dictation: DictationActivity
        /// The user's dictionary for Whisper and the cloud, read per job.
        public var prompt: @Sendable () async -> String?
        /// Keeps App Nap away while the queue works; returns what ends it.
        public var beginWork: @Sendable () -> @Sendable () -> Void
        public var windows: WindowSettings
        public var now: @Sendable () -> Date

        public init(folder: RecordingsFolder, opener: any LongAudioOpener, detector: (any SpeechDetector)?,
                    makeEngine: @escaping @Sendable (String) -> (any SpeechEngine)?,
                    makeDiarizer: @escaping @Sendable () -> (any DiarizerEngine)?,
                    dictation: DictationActivity, prompt: @escaping @Sendable () async -> String? = { nil },
                    beginWork: @escaping @Sendable () -> @Sendable () -> Void = FileTranscriber.appNapOff,
                    windows: WindowSettings = .standard, now: @escaping @Sendable () -> Date = Date.init)
        {
            self.folder = folder
            self.opener = opener
            self.detector = detector
            self.makeEngine = makeEngine
            self.makeDiarizer = makeDiarizer
            self.dictation = dictation
            self.prompt = prompt
            self.beginWork = beginWork
            self.windows = windows
            self.now = now
        }
    }

    /// `ProcessInfo.beginActivity` for user-initiated work, which App Nap
    /// leaves alone; idle sleep stays allowed.
    public static let appNapOff: @Sendable () -> @Sendable () -> Void = {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Transcribing a recording")
        // Ended once, by the queue that began it.
        nonisolated(unsafe) let held = activity
        return { ProcessInfo.processInfo.endActivity(held) }
    }

    private struct Running {
        let job: TranscriptionJob
        let task: Task<Void, Never>
        /// The user cancelled it, or queued it again: its progress goes.
        var dropsProgress = false
    }

    private enum Stop: Error {
        case failed(TranscriptionFailure)
    }

    private let environment: Environment
    private let log = Logger(subsystem: "app.perekey", category: "transcription")
    private var queue: [TranscriptionJob] = []
    private var running: Running?
    private var states: [UUID: TranscriptionPhase] = [:]
    private var observers: [UUID: AsyncStream<[UUID: TranscriptionPhase]>.Continuation] = [:]
    private var engine: (any SpeechEngine)?
    private var detectorReady = false
    private var endWork: (@Sendable () -> Void)?
    private nonisolated let busy = OSAllocatedUnfairLock(initialState: false)
    /// Runs over, whatever came of them: tests wait for it.
    public private(set) var runsDone = 0

    public init(environment: Environment) {
        self.environment = environment
    }

    public nonisolated var isBusy: Bool { busy.withLock { $0 } }

    public func enqueue(_ job: TranscriptionJob) {
        try? environment.folder.updateMeta(job.recording) { $0.pendingJob = job }
        if let index = queue.firstIndex(where: { $0.recording == job.recording }) {
            queue[index] = job
        } else {
            queue.append(job)
        }
        if running?.job.recording == job.recording {
            running?.dropsProgress = true
            running?.task.cancel()
        }
        set(job.recording, .queued)
        pump()
    }

    public func cancel(_ recording: UUID) {
        if let index = queue.firstIndex(where: { $0.recording == recording }) {
            queue.remove(at: index)
            settle(recording, keepingProgress: false)
            set(recording, .cancelled)
        }
        if running?.job.recording == recording {
            running?.dropsProgress = true
            running?.task.cancel()
        }
        updateBusy()
    }

    /// Queues the recordings a quit or a crash cut off: those with a
    /// `pendingJob`. They go on from their last window.
    public func resumePending() {
        for id in environment.folder.recordings() {
            guard case let .loaded(meta) = environment.folder.meta(id), let job = meta.pendingJob,
                  job.recording == id, running?.job.recording != id, !queue.contains(where: { $0.recording == id })
            else { continue }
            queue.append(job)
            set(id, .queued)
        }
        pump()
    }

    /// Stops for quit: what is done stays, and `resumePending` goes on with it.
    public func shutdown() async {
        queue = []
        let task = running?.task
        task?.cancel()
        await task?.value
        await unloadModels()
        updateBusy()
    }

    public nonisolated func phases() -> AsyncStream<[UUID: TranscriptionPhase]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
            Task { await self.addObserver(id, continuation) }
        }
    }

    // MARK: - Queue

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<[UUID: TranscriptionPhase]>.Continuation) {
        observers[id] = continuation
        continuation.yield(states)
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func set(_ recording: UUID, _ phase: TranscriptionPhase) {
        guard states[recording] != phase else { return }
        states[recording] = phase
        for observer in observers.values { observer.yield(states) }
    }

    private func updateBusy() {
        let working = running != nil || !queue.isEmpty
        busy.withLock { $0 = working }
        if working, endWork == nil {
            endWork = environment.beginWork()
        } else if !working, let end = endWork {
            endWork = nil
            end()
        }
    }

    private func pump() {
        defer { updateBusy() }
        guard running == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = Running(job: job, task: Task { await self.run(job) })
    }

    private func run(_ job: TranscriptionJob) async {
        let started = ContinuousClock.now
        let phase = await transcribe(job)
        let dropsProgress = running?.dropsProgress ?? false
        let queuedAgain = queue.contains { $0.recording == job.recording }
        if phase == .cancelled, !dropsProgress {
            // Quit: the progress and the pending job stay for the next launch.
        } else if !queuedAgain {
            if phase != .done { settle(job.recording, keepingProgress: false) }
            set(job.recording, phase)
        }
        let outcome = String(describing: phase)
        let elapsed = String(describing: ContinuousClock.now - started)
        log.info("transcription \(outcome, privacy: .public) in \(elapsed, privacy: .public)")
        if queue.isEmpty { await unloadModels() }
        running = nil
        runsDone += 1
        pump()
    }

    /// The recording is no longer in work: its state goes back to what the
    /// transcript on disk says.
    private func settle(_ recording: UUID, keepingProgress: Bool) {
        let folder = environment.folder
        var hasTranscript = false
        if case .loaded = folder.transcript(recording) { hasTranscript = true }
        try? folder.updateMeta(recording) { meta in
            meta.pendingJob = nil
            if meta.state == .transcribing { meta.state = hasTranscript ? .done : .stopped }
        }
        if !keepingProgress { folder.removePartial(recording) }
    }

    private func unloadModels() async {
        await engine?.unload()
        engine = nil
        if detectorReady { await environment.detector?.unload() }
        detectorReady = false
    }

    // MARK: - One recording

    private func transcribe(_ job: TranscriptionJob) async -> TranscriptionPhase {
        do {
            try await work(job)
            return .done
        } catch is CancellationError {
            return .cancelled
        } catch let Stop.failed(failure) {
            return Task.isCancelled ? .cancelled : .failed(failure)
        } catch let error as RecordingsFolder.FileError {
            if case .newerVersion = error { return .failed(.newerVersion) }
            return .failed(.storageFailed)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(.storageFailed)
        }
    }

    private func work(_ job: TranscriptionJob) async throws {
        let id = job.recording
        let folder = environment.folder
        let meta = try folder.updateMeta(id) { meta in
            meta.state = .transcribing
            meta.pendingJob = job
        }
        let directory = folder.directory(for: id)
        var sources: [(key: String, source: AudioSource)] = []
        switch meta.kind {
        case .file:
            if let source = meta.audio(in: directory) { sources.append(("file", source)) }
        case .call:
            for track in meta.tracks {
                if let source = meta.audio(of: track, in: directory) { sources.append((track.rawValue, source)) }
            }
        }
        guard !sources.isEmpty else { throw Stop.failed(meta.kind == .file ? .sourceMissing : .unreadable) }

        set(id, .preparingModel)
        let engine = try await prepareEngine(job.model)
        if !detectorReady, let detector = environment.detector {
            detectorReady = (try? await detector.prepare()) != nil
        }
        try Task.checkCancellation()
        let prompt = await environment.prompt()

        var audios: [(key: String, audio: any LongAudio)] = []
        defer { audios.forEach { $0.audio.close() } }
        for (key, source) in sources {
            do {
                audios.append((key, try await environment.opener.open(source)))
            } catch let error as LongAudioError {
                throw Stop.failed(error == .missing ? .sourceMissing : .unreadable)
            } catch {
                throw Stop.failed(.unreadable)
            }
        }
        let total = audios.reduce(0) { $0 + $1.audio.sampleCount }
        guard total > 0 else { throw Stop.failed(.unreadable) }

        var partial = folder.partial(id).flatMap { $0.model == job.model ? $0 : nil }
            ?? TranscriptionCheckpoint(model: job.model)
        var done = audios.filter { partial.finished[$0.key] != nil }.reduce(0) { $0 + $1.audio.sampleCount }
        set(id, .transcribing(Double(done) / Double(total)))
        for (key, audio) in audios where partial.finished[key] == nil {
            if partial.track != key {
                partial.track = key
                partial.position = 0
                partial.stitcher = WindowStitcher()
                partial.language = job.language
            }
            let transcript = try await transcribeTrack(audio, id: id, engine: engine, prompt: prompt, partial: &partial,
                                                  done: done, total: total)
            partial.finished[key] = transcript
            partial.track = nil
            try? folder.savePartial(partial, id: id)
            done += audio.sampleCount
        }
        let duration = Double(audios.map(\.audio.sampleCount).max() ?? 0) / VoiceCore.sampleRate
        audios.forEach { $0.audio.close() }
        audios = []

        var turns: [SpeakerTurn]?
        if job.diarize, let target = sources.first(where: { $0.key == "file" || $0.key == RecordingTrack.sys.rawValue }) {
            turns = try await diarize(target.source, id: id)
        }

        let empty = TimedTranscript(segments: [])
        var result: TimedTranscript
        switch meta.kind {
        case .file:
            result = partial.finished["file"] ?? empty
            if let turns { result.segments = TranscriptMerger.attribute(result.segments, to: turns) }
        case .call:
            var others = partial.finished[RecordingTrack.sys.rawValue] ?? empty
            if let turns { others.segments = TranscriptMerger.attribute(others.segments, to: turns) }
            result = TranscriptMerger.merge(me: partial.finished[RecordingTrack.mic.rawValue] ?? empty, others: others)
        }
        let document = TranscriptDocument(model: job.model, engine: Self.engineName(job.model),
                                          language: job.language ?? result.language, createdAt: environment.now(),
                                          segments: result.segments)
        try Task.checkCancellation()
        try folder.updateTranscript(id) { old in
            old = old.map(document.keepingNames(from:)) ?? document
        }
        try folder.updateMeta(id) { meta in
            meta.state = .done
            meta.pendingJob = nil
            meta.duration = meta.duration ?? duration
        }
        folder.removePartial(id)
    }

    /// One track, window after window, from where `partial` stopped.
    private func transcribeTrack(_ audio: any LongAudio, id: UUID, engine: any SpeechEngine, prompt: String?,
                            partial: inout TranscriptionCheckpoint, done: Int, total: Int) async throws
        -> TimedTranscript
    {
        let rate = VoiceCore.sampleRate
        let settings = environment.windows
        let chunk = VoiceActivity.chunk
        let window = Int(settings.window * rate)
        let overlap = Int(settings.overlap * rate)
        let search = Int(settings.search * rate)
        let count = audio.sampleCount
        while partial.position < count {
            let progress = Double(done + partial.position) / Double(total)
            try await yieldToDictation(id, progress: progress)
            let position = partial.position
            let end = min(position + window, count)
            let samples = try audio.read(position..<end)
            var probabilities: [Float]?
            if detectorReady, let detector = environment.detector {
                probabilities = try? await detector.speechProbabilities(samples)
            }
            var cut = end
            if end < count {
                let tailStart = max(0, samples.count - search) / chunk * chunk
                if let probabilities, probabilities.count > tailStart / chunk {
                    cut = position + WindowCut.cut(probabilities: Array(probabilities[(tailStart / chunk)...]),
                                                   tailStart: tailStart)
                }
                // The next window must start later than this one.
                if cut - overlap <= position { cut = end }
            }
            let length = cut - position
            let speech = probabilities.map { VoiceActivity.hasSpeech(Array($0.prefix((length + chunk - 1) / chunk))) }
            var found = TimedTranscript(segments: [])
            if speech ?? true {
                do {
                    found = try await engine.transcribeTimed(
                        AudioBuffer16k(Array(samples[0..<length])), language: partial.language, prompt: prompt)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw Stop.failed(.engineFailed)
                }
                // Whisper: the first window with speech sets the track's language.
                if partial.language == nil, !found.segments.isEmpty { partial.language = found.language }
            }
            let last = end >= count
            partial.stitcher.add(found, offset: Double(position) / rate,
                                 keepUntil: last ? nil : Double(cut) / rate - settings.overlap / 2)
            partial.position = last ? count : cut - overlap
            try? environment.folder.savePartial(partial, id: id)
            set(id, .transcribing(Double(done + partial.position) / Double(total)))
        }
        return partial.stitcher.transcript(language: partial.language)
    }

    private func yieldToDictation(_ id: UUID, progress: Double) async throws {
        try Task.checkCancellation()
        if environment.dictation.isActive {
            set(id, .waitingForDictation(progress))
            await environment.dictation.idle()
            set(id, .transcribing(progress))
        }
        try Task.checkCancellation()
    }

    private func diarize(_ source: AudioSource, id: UUID) async throws -> [SpeakerTurn] {
        set(id, .diarizing(0))
        guard let diarizer = environment.makeDiarizer() else { throw Stop.failed(.modelUnavailable) }
        do {
            try await diarizer.prepare()
        } catch {
            throw Stop.failed(.modelUnavailable)
        }
        defer { Task { await diarizer.unload() } }
        do {
            let turns = try await diarizer.diarize(source) { [weak self] fraction in
                Task { await self?.set(id, .diarizing(min(1, max(0, fraction)))) }
            }
            try Task.checkCancellation()
            return turns
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Stop.failed(.engineFailed)
        }
    }

    private func prepareEngine(_ model: String) async throws -> any SpeechEngine {
        if let engine, engine.id != model {
            await engine.unload()
            self.engine = nil
        }
        if engine == nil {
            guard let made = environment.makeEngine(model) else { throw Stop.failed(.modelUnavailable) }
            engine = made
        }
        guard let engine else { throw Stop.failed(.modelUnavailable) }
        do {
            try await engine.prepare()
        } catch {
            await engine.unload()
            self.engine = nil
            throw Stop.failed(.modelUnavailable)
        }
        return engine
    }

    /// The `engine` of `transcript.json`.
    public static func engineName(_ model: String) -> String {
        switch ModelCatalog.entry(id: model)?.engine {
        case .fluidAudioAsr: "parakeet"
        case .whisperKit: "whisper"
        case .fluidAudioVad, .fluidAudioDiarizer: model
        case nil: "cloud"
        }
    }
}

/// Why `LongAudioOpener.open` failed.
public enum LongAudioError: Error, Equatable, Sendable {
    /// The file is gone, or its bookmark no longer opens it.
    case missing
    /// It is not audio AVFoundation reads, or holds no audio.
    case unreadable
}
