// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyVoiceCore
import Testing

/// Audio whose every sample is its own number on the track (plus `base`):
/// the fakes below read where on the track a window lies from its samples.
struct NumberedAudio: LongAudio {
    let sampleCount: Int
    let base: Int
    let closed = OSAllocatedUnfairLock(initialState: false)

    func read(_ range: Range<Int>) throws -> [Float] {
        range.map { $0 < sampleCount ? Float(base + $0) : 0 }
    }

    func close() { closed.withLock { $0 = true } }
}

let sysBase = 10_000_000

struct NumberedOpener: LongAudioOpener {
    var seconds: [RecordingTrack: Double] = [:]
    var fileSeconds: Double = 0
    var missing = false

    func open(_ source: AudioSource) async throws -> any LongAudio {
        if missing { throw LongAudioError.missing }
        switch source {
        case .file: return NumberedAudio(sampleCount: Int(fileSeconds * 16_000), base: 0)
        case let .track(track, _):
            return NumberedAudio(sampleCount: Int((seconds[track] ?? 0) * 16_000), base: track == .sys ? sysBase : 0)
        }
    }
}

/// Speaks the words of a script that start inside the window it gets,
/// with times from the window's start; can hold a window until released.
actor ScriptEngine: SpeechEngine {
    nonisolated let id: String
    let script: [RecordingTrack: [TimedWord]]
    private(set) var windows: [(track: RecordingTrack, start: Double, end: Double)] = []
    private(set) var languages: [String?] = []
    private(set) var prompts: [String?] = []
    private(set) var unloads = 0
    private var holds = false
    private var gate: CheckedContinuation<Void, Never>?
    private var arrived: [CheckedContinuation<Void, Never>] = []

    /// Phrases without word timings, one per word of the script: the cloud.
    let wordless: Bool

    init(id: String = "parakeet-tdt-v3", script: [RecordingTrack: [TimedWord]], wordless: Bool = false) {
        self.id = id
        self.script = script
        self.wordless = wordless
    }

    func prepare() async throws {}
    func unload() async { unloads += 1 }
    func transcribe(_: AudioBuffer16k) async throws -> Transcript { Transcript(text: "") }

    func hold() { holds = true }

    func release() {
        holds = false
        gate?.resume()
        gate = nil
    }

    /// Returns once a window is held.
    func waitForHeldWindow() async {
        if gate != nil { return }
        await withCheckedContinuation { arrived.append($0) }
    }

    func transcribeTimed(_ audio: AudioBuffer16k, language: String?, prompt: String?) async throws -> TimedTranscript {
        let first = Int(audio.samples.first ?? 0)
        let track: RecordingTrack = first >= sysBase ? .sys : .mic
        let start = Double(first - (track == .sys ? sysBase : 0)) / 16_000
        let end = start + audio.seconds
        windows.append((track, start, end))
        languages.append(language)
        prompts.append(prompt)
        if holds {
            await withCheckedContinuation { continuation in
                gate = continuation
                arrived.forEach { $0.resume() }
                arrived = []
            }
        }
        let words = (script[track] ?? []).filter { $0.start >= start && $0.start < end }.map { $0.shifted(by: -start) }
        if wordless {
            return TimedTranscript(segments: words.map {
                TimedSegment(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespaces))
            }, language: "en")
        }
        guard let first = words.first, let last = words.last else { return TimedTranscript(segments: [], language: "en") }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        return TimedTranscript(segments: [TimedSegment(start: first.start, end: last.end, text: text, words: words)],
                               language: "en")
    }
}

/// Speech everywhere but in `silences` (seconds on the track).
struct SilenceDetector: SpeechDetector {
    var silences: [ClosedRange<Double>] = []

    func prepare() async throws {}
    func unload() async {}

    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        stride(from: 0, to: samples.count, by: VoiceActivity.chunk).map { i in
            let number = Int(samples[i]) % sysBase
            let seconds = Double(number) / 16_000 + VoiceActivity.chunkSeconds / 2
            return silences.contains { $0.contains(seconds) } ? 0.05 : 0.9
        }
    }
}

actor FakeDiarizer: DiarizerEngine {
    nonisolated let id = "diarizer-offline-vbx"
    let turns: [SpeakerTurn]
    /// The `base` of each audio it got: `sysBase` for the others' track.
    private(set) var bases: [Int] = []

    init(turns: [SpeakerTurn]) { self.turns = turns }

    func prepare() async throws {}
    func unload() async {}

    func diarize(_ audio: any LongAudio, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerTurn] {
        bases.append((audio as? NumberedAudio)?.base ?? -1)
        progress(0.5)
        // A report that comes after the end, as FluidAudio's may.
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            progress(0.9)
        }
        return turns
    }
}

/// Words " w0" " w1" … every `step` seconds, 0.4 s long.
private func words(_ count: Int, from start: Double = 0.3, step: Double = 0.7, prefix: String = "w") -> [TimedWord] {
    (0..<count).map { TimedWord(start: start + Double($0) * step, end: start + Double($0) * step + 0.4,
                                text: " \(prefix)\($0)") }
}

struct FileTranscriberTests {
    final class Fixture {
        let root = URL.temporaryDirectory.appending(path: "perekey-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        var folder: RecordingsFolder { RecordingsFolder(root: root) }
        let dictation = DictationActivity()
        let work = OSAllocatedUnfairLock(initialState: (begun: 0, ended: 0))
        /// Engines made, by model.
        let made = OSAllocatedUnfairLock(initialState: [String]())

        deinit { try? FileManager.default.removeItem(at: root) }

        func call(seconds: Double) throws -> UUID {
            var meta = RecordingMeta.call(source: .system, startHostTime: 1, audioRetention: .always)
            meta.state = .stopped
            meta.segments = [
                .init(track: .mic, file: "mic-0001.aac", startHostTime: 1, startOffset: 0,
                      frames: Int64(seconds * 16_000), closed: true),
                .init(track: .sys, file: "sys-0001.aac", startHostTime: 1, startOffset: 0,
                      frames: Int64(seconds * 16_000), closed: true),
            ]
            return try folder.create(meta, excludedFromBackup: true)
        }

        func file() throws -> UUID {
            try folder.create(.file(FileReference(path: "/tmp/talk.mp3")), excludedFromBackup: true)
        }

        func queue(engine: ScriptEngine?, opener: NumberedOpener, detector: SilenceDetector? = SilenceDetector(),
                   diarizer: FakeDiarizer? = nil, windows: WindowSettings = .standard,
                   mayUpload: @escaping @Sendable (String) async -> Bool = { !TranscriptionModel.isCloud($0) })
            -> FileTranscriber
        {
            FileTranscriber(environment: environment(engine: engine, opener: opener, detector: detector,
                                                     diarizer: diarizer, windows: windows, mayUpload: mayUpload))
        }

        func environment(engine: ScriptEngine?, opener: NumberedOpener, detector: SilenceDetector? = SilenceDetector(),
                         diarizer: FakeDiarizer? = nil, windows: WindowSettings = .standard,
                         mayUpload: @escaping @Sendable (String) async -> Bool = { !TranscriptionModel.isCloud($0) })
            -> FileTranscriber.Environment
        {
            let work = self.work
            let made = self.made
            return .init(
                folder: folder, opener: opener, detector: detector,
                makeEngine: { id in
                    made.withLock { $0.append(id) }
                    return engine.flatMap { $0.id == id ? $0 : nil }
                },
                makeDiarizer: { diarizer }, dictation: dictation, prompt: { "Perekey" }, mayUpload: mayUpload,
                beginWork: {
                    work.withLock { $0.begun += 1 }
                    return { work.withLock { $0.ended += 1 } }
                },
                windows: windows, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        }

        func transcript(_ id: UUID) -> TranscriptDocument? {
            if case let .loaded(document) = folder.transcript(id) { return document }
            return nil
        }

        func meta(_ id: UUID) -> RecordingMeta? {
            if case let .loaded(meta) = folder.meta(id) { return meta }
            return nil
        }
    }

    /// Waits for the recording to reach a phase that `until` accepts.
    @discardableResult
    private func wait(_ queue: FileTranscriber, _ id: UUID, until: (TranscriptionPhase) -> Bool) async
        -> [TranscriptionPhase]
    {
        var seen: [TranscriptionPhase] = []
        for await phases in await queue.phases() {
            guard let phase = phases[id] else { continue }
            if seen.last != phase { seen.append(phase) }
            if until(phase) { break }
        }
        return seen
    }

    private func finished(_ phase: TranscriptionPhase) -> Bool { !phase.isPending }

    /// Waits until the queue has wound up `runs` runs, models unloaded.
    private func settled(_ queue: FileTranscriber, runs: Int) async {
        while await queue.runsDone < runs {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Five minutes in windows of 60 s with pauses: every word once, in
    /// place, though a word sits on almost every edge.
    @Test func windowsLoseAndDoubleNothing() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 300)
        let script = words(420)
        let engine = ScriptEngine(script: [.mic: script])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 300]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        let phases = await wait(queue, id, until: finished)
        #expect(phases.last == .done)
        let document = try #require(fixture.transcript(id))
        let found = document.segments.flatMap { $0.words ?? [] }
        #expect(found.map(\.text) == script.map(\.text))
        for (a, b) in zip(found, script) {
            #expect(abs(a.start - b.start) < 1e-6 && abs(a.end - b.end) < 1e-6)
        }
        #expect(document.segments.allSatisfy { $0.speaker == "me" })
        #expect(document.engine == "parakeet" && document.language == "en")
        let windows = await engine.windows
        #expect(windows.count >= 5)
        // Each next window starts 2 s before the last one's cut.
        #expect(windows.allSatisfy { $0.end - $0.start <= 60 + 1e-9 })
        #expect(fixture.meta(id)?.state == .done)
        #expect(fixture.meta(id)?.pendingJob == nil)
        #expect(fixture.meta(id)?.duration == 300)
        #expect(fixture.folder.partial(id) == nil)
        #expect(await engine.prompts.allSatisfy { $0 == "Perekey" })
        await settled(queue, runs: 1)
        #expect(!queue.isBusy)
        let work = fixture.work.withLock { $0 }
        #expect(work.begun == 1 && work.ended == 1)
    }

    /// The window ends in the silence of its last 15 s; windows without
    /// speech never reach the model.
    @Test func cutsFallInSilence() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 150)
        let engine = ScriptEngine(script: [.mic: words(10, from: 1)])
        let detector = SilenceDetector(silences: [50...52, 100...150])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 150]), detector: detector)
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await wait(queue, id, until: finished)
        let windows = await engine.windows
        // The first cut is in 50…52 s; the window from 49 s to the next cut
        // has speech; the last, silent to the end, is skipped.
        let firstEnd = try #require(windows.first?.end)
        #expect(firstEnd > 50 && firstEnd < 52)
        #expect(abs((windows.dropFirst().first?.start ?? 0) - (firstEnd - 2)) < 1e-6)
        #expect(windows.allSatisfy { $0.start < 100 })
    }

    /// 60 s is not a whole number of VAD chunks: a quiet last chunk, cut in
    /// its middle, would end the window past its audio.
    @Test func quietShortLastChunk() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 130)
        let script = words(180)
        let engine = ScriptEngine(script: [.mic: script])
        let detector = SilenceDetector(silences: [60.0...60.1])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 130]), detector: detector)
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        #expect(await wait(queue, id, until: finished).last == .done)
        #expect(await engine.windows.first?.end == 60)
        let found = try #require(fixture.transcript(id)).segments.flatMap { $0.words ?? [] }
        #expect(found.map(\.text) == script.map(\.text))
    }

    /// The consent taken back after a window: the next one never leaves.
    @Test func consentTakenBackStopsTheNextWindow() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let model = "cloud:groq:whisper-large-v3-turbo"
        let engine = ScriptEngine(id: model, script: [.mic: words(280)], wordless: true)
        await engine.hold()
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 200]),
                                  mayUpload: { _ in allowed.withLock { $0 } })
        await queue.enqueue(TranscriptionJob(recording: id, model: model, diarize: false))
        await engine.waitForHeldWindow()
        allowed.withLock { $0 = false }
        await engine.release()
        #expect(await wait(queue, id, until: finished).last == .failed(.needsConsent))
        #expect(await engine.windows.count == 1)
    }

    /// Dictation goes first: the queue stops at the edge of the window in
    /// work and goes on once the text is in.
    @Test func dictationPausesAtTheWindowEdge() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let engine = ScriptEngine(script: [.mic: words(200)])
        await engine.hold()
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 200]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await engine.waitForHeldWindow()
        fixture.dictation.began()
        await engine.release()
        await wait(queue, id) { if case .waitingForDictation = $0 { true } else { false } }
        #expect(await engine.windows.count == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.windows.count == 1)
        fixture.dictation.ended()
        let phases = await wait(queue, id, until: finished)
        #expect(phases.last == .done)
        #expect(await engine.windows.count > 1)
    }

    @Test func cancelStopsAtTheNextEdge() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let engine = ScriptEngine(script: [.mic: words(200)])
        await engine.hold()
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 200]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await engine.waitForHeldWindow()
        await queue.cancel(id)
        await engine.release()
        let phases = await wait(queue, id, until: finished)
        #expect(phases.last == .cancelled)
        #expect(await engine.windows.count == 1)
        #expect(fixture.transcript(id) == nil)
        #expect(fixture.meta(id)?.state == .stopped)
        #expect(fixture.meta(id)?.pendingJob == nil)
        #expect(fixture.folder.partial(id) == nil)
        await settled(queue, runs: 1)
        #expect(await engine.unloads == 1)
    }

    /// Cancelling while the queue waits for dictation ends the wait.
    @Test func cancelDuringDictation() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        fixture.dictation.began()
        let queue = fixture.queue(engine: ScriptEngine(script: [:]), opener: NumberedOpener(seconds: [.mic: 200]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await wait(queue, id) { if case .waitingForDictation = $0 { true } else { false } }
        await queue.cancel(id)
        #expect(await wait(queue, id, until: finished).last == .cancelled)
    }

    /// A quit keeps what is done; the next launch goes on from the window after it.
    @Test func quitResumesFromTheLastWindow() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let script = words(280)
        let first = ScriptEngine(script: [.mic: script])
        await first.hold()
        let queue = fixture.queue(engine: first, opener: NumberedOpener(seconds: [.mic: 200]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await letThrough(first, windows: 2)
        let shutdown = Task { await queue.shutdown() }
        await first.release()
        await shutdown.value
        #expect(fixture.meta(id)?.state == .transcribing)
        #expect(fixture.meta(id)?.pendingJob?.model == "parakeet-tdt-v3")
        let saved = try #require(fixture.folder.partial(id))
        #expect(saved.position > 0)

        let second = ScriptEngine(script: [.mic: script])
        let next = fixture.queue(engine: second, opener: NumberedOpener(seconds: [.mic: 200]))
        await next.resumePending()
        #expect(await wait(next, id, until: finished).last == .done)
        #expect(abs((await second.windows.first?.start ?? 0) - Double(saved.position) / 16_000) < 1e-6)
        let found = try #require(fixture.transcript(id)).segments.flatMap { $0.words ?? [] }
        #expect(found.map(\.text) == script.map(\.text))
    }

    /// Lets `count` windows through and returns while the next one is held.
    private func letThrough(_ engine: ScriptEngine, windows count: Int) async {
        for _ in 0..<count {
            await engine.waitForHeldWindow()
            await engine.release()
            await engine.hold()
        }
        await engine.waitForHeldWindow()
    }

    /// Two tracks: «Я» without the echo of the others, the others split by voice.
    @Test func callTracksMergeWithEchoGoneAndVoicesSplit() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 30)
        let mine = [
            TimedWord(start: 1, end: 1.4, text: " Привет,"), TimedWord(start: 1.5, end: 1.9, text: " как"),
            TimedWord(start: 2, end: 2.4, text: " дела?"),
            // The others' words on the speakers.
            TimedWord(start: 10.2, end: 10.6, text: " отлично"), TimedWord(start: 10.7, end: 11, text: " спасибо"),
        ]
        let theirs = [
            TimedWord(start: 10, end: 10.4, text: " Отлично,"), TimedWord(start: 10.5, end: 10.9, text: " спасибо."),
            TimedWord(start: 20, end: 20.4, text: " Да."),
        ]
        let engine = ScriptEngine(script: [.mic: mine, .sys: theirs])
        let diarizer = FakeDiarizer(turns: [
            SpeakerTurn(start: 9, end: 15, speaker: 3), SpeakerTurn(start: 19, end: 22, speaker: 0),
        ])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 30, .sys: 30]),
                                  diarizer: diarizer)
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: true))
        #expect(await wait(queue, id, until: finished).last == .done)
        let document = try #require(fixture.transcript(id))
        #expect(document.segments.map(\.text) == ["Привет, как дела?", "Отлично, спасибо.", "Да."])
        #expect(document.segments.map(\.speaker) == ["me", "speaker-1", "speaker-2"])
        #expect(document.speakers.map(\.id) == ["me", "speaker-1", "speaker-2"])
        // The others' track, the one already open.
        #expect(await diarizer.bases == [sysBase])
        // A late progress report does not take the phase back.
        try await Task.sleep(for: .milliseconds(60))
        #expect(await wait(queue, id, until: { _ in true }).last == .done)
    }

    /// «Расшифровать заново» with another model: the names of the tracks stay.
    @Test func retranscribeKeepsTrackNames() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 10)
        let script: [RecordingTrack: [TimedWord]] = [.mic: words(5), .sys: words(5, from: 5, prefix: "x")]
        let parakeet = ScriptEngine(script: script)
        let queue = fixture.queue(engine: parakeet, opener: NumberedOpener(seconds: [.mic: 10, .sys: 10]))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await wait(queue, id, until: finished)
        try fixture.folder.updateTranscript(id) {
            $0?.rename(speaker: "me", to: "Олег")
            $0?.rename(speaker: "others", to: "Клиент")
        }
        let whisper = ScriptEngine(id: "whisper-large-v3-turbo-632mb", script: script)
        let again = fixture.queue(engine: whisper, opener: NumberedOpener(seconds: [.mic: 10, .sys: 10]))
        await again.enqueue(TranscriptionJob(recording: id, model: "whisper-large-v3-turbo-632mb", diarize: false))
        #expect(await wait(again, id, until: finished).last == .done)
        let document = try #require(fixture.transcript(id))
        #expect(document.engine == "whisper")
        #expect(document.speakers.map(\.name) == ["Олег", "Клиент"])
    }

    /// Whisper's language: found in the first window with speech, then given.
    @Test func languageIsFoundOncePerTrack() async throws {
        let fixture = Fixture()
        let id = try fixture.file()
        let engine = ScriptEngine(id: "whisper-large-v3-turbo-632mb", script: [.mic: words(200)])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(fileSeconds: 150))
        await queue.enqueue(TranscriptionJob(recording: id, model: "whisper-large-v3-turbo-632mb", diarize: false))
        await wait(queue, id, until: finished)
        let languages = await engine.languages
        #expect(languages.first == .some(nil))
        #expect(languages.dropFirst().allSatisfy { $0 == "en" })
        let document = try #require(fixture.transcript(id))
        #expect(document.segments.allSatisfy { $0.speaker == nil })
    }

    @Test func failures() async throws {
        let fixture = Fixture()
        let id = try fixture.file()
        let queue = fixture.queue(engine: nil, opener: NumberedOpener(fileSeconds: 10))
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        #expect(await wait(queue, id, until: finished).last == .failed(.modelUnavailable))
        #expect(fixture.meta(id)?.state == .stopped)
        #expect(fixture.meta(id)?.pendingJob == nil)

        let gone = fixture.queue(engine: ScriptEngine(script: [:]), opener: NumberedOpener(missing: true))
        await gone.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        #expect(await wait(gone, id, until: finished).last == .failed(.sourceMissing))

        let noDiarizer = fixture.queue(engine: ScriptEngine(script: [:]), opener: NumberedOpener(fileSeconds: 10))
        await noDiarizer.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: true))
        #expect(await wait(noDiarizer, id, until: finished).last == .failed(.modelUnavailable))
    }

    /// Phrases without word timings (the cloud): windows meet at the cut,
    /// and the phrase after a cut is kept.
    @Test func wordlessPhrasesMeetAtTheCut() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let script = words(280)
        let engine = ScriptEngine(id: "cloud:groq:whisper-large-v3-turbo", script: [.mic: script], wordless: true)
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 200]),
                                  detector: SilenceDetector(silences: [50...51, 100...101, 150...151]),
                                  mayUpload: { _ in true })
        await queue.enqueue(TranscriptionJob(recording: id, model: "cloud:groq:whisper-large-v3-turbo", diarize: false))
        #expect(await wait(queue, id, until: finished).last == .done)
        let windows = await engine.windows
        #expect(windows.count == 4)
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(abs(a.end - b.start) < 1e-9)
        }
        let document = try #require(fixture.transcript(id))
        #expect(document.segments.map(\.text) == script.map { $0.text.trimmingCharacters(in: .whitespaces) })
        #expect(document.engine == "cloud")
    }

    /// A cloud model chosen for files without the consent for
    /// conversations: no engine is made, nothing is sent.
    @Test func cloudWithoutConsentNeedsIt() async throws {
        let fixture = Fixture()
        let id = try fixture.file()
        let engine = ScriptEngine(id: "cloud:openai:gpt-4o-transcribe", script: [:])
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(fileSeconds: 10))
        await queue.enqueue(TranscriptionJob(recording: id, model: "cloud:openai:gpt-4o-transcribe", diarize: false))
        #expect(await wait(queue, id, until: finished).last == .failed(.needsConsent))
        #expect(fixture.made.withLock { $0 }.isEmpty)
        #expect(await engine.windows.isEmpty)
        #expect(fixture.meta(id)?.state == .stopped)
    }

    @Test func modelForTranscriptions() {
        // As dictation, on this Mac.
        #expect(TranscriptionModel.resolve(chosen: nil, dictation: "whisper-large-v3-turbo-632mb")
            == "whisper-large-v3-turbo-632mb")
        // A cloud model for dictation is no consent for recordings: the default local one.
        #expect(TranscriptionModel.resolve(chosen: nil, dictation: "cloud:groq:whisper-large-v3-turbo")
            == DictationPreferences.defaultModel)
        // The cloud by the user's own choice.
        #expect(TranscriptionModel.resolve(chosen: "cloud:groq:whisper-large-v3-turbo", dictation: "parakeet-tdt-v3")
            == "cloud:groq:whisper-large-v3-turbo")
        #expect(TranscriptionModel.resolve(chosen: "", dictation: "parakeet-tdt-v3") == "parakeet-tdt-v3")
    }

    /// Queued again with another job while it runs: it starts over, without
    /// the windows of the old job. The same job again changes nothing.
    @Test func requeueWithAnotherJobStartsOver() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let script = words(280)
        let engine = ScriptEngine(script: [.mic: script])
        await engine.hold()
        let queue = fixture.queue(engine: engine, opener: NumberedOpener(seconds: [.mic: 200]))
        let job = TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false)
        await queue.enqueue(job)
        await letThrough(engine, windows: 1)
        await queue.enqueue(job)
        #expect(await queue.runsDone == 0)
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false, language: "en"))
        await engine.release()
        #expect(await wait(queue, id, until: finished).last == .done)
        let starts = await engine.windows.map(\.start)
        // The first job's two windows, then the new job from the start.
        #expect(starts.filter { $0 == 0 }.count == 2)
        let found = try #require(fixture.transcript(id)).segments.flatMap { $0.words ?? [] }
        #expect(found.map(\.text) == script.map(\.text))
        #expect(fixture.transcript(id)?.language == "en")
    }

    /// Voice off and on at once: the new queue waits for the old one to let
    /// go, then goes on from its last window; one queue writes the progress.
    @MainActor
    @Test func stopThenStartWaitsForTheOldQueue() async throws {
        let fixture = Fixture()
        let id = try fixture.call(seconds: 200)
        let script = words(280)
        let first = ScriptEngine(script: [.mic: script])
        await first.hold()
        let second = ScriptEngine(script: [.mic: script])
        var engines = [first, second]
        let cleaned = OSAllocatedUnfairLock(initialState: [Date]())
        let lifecycle = FileQueueLifecycle(
            environment: { fixture.environment(engine: engines.removeFirst(), opener: NumberedOpener(seconds: [.mic: 200])) },
            clean: { date in cleaned.withLock { $0.append(date) } })
        lifecycle.start()
        await lifecycle.resuming?.value
        #expect(cleaned.withLock { $0 }.count == 1)
        let queue = try #require(lifecycle.queue)
        await queue.enqueue(TranscriptionJob(recording: id, model: "parakeet-tdt-v3", diarize: false))
        await letThrough(first, windows: 1)
        lifecycle.stop()
        lifecycle.start()
        let next = try #require(lifecycle.queue)
        // A recording queued in the new queue waits too.
        let other = try fixture.call(seconds: 20)
        await next.enqueue(TranscriptionJob(recording: other, model: "parakeet-tdt-v3", diarize: false))
        try await Task.sleep(for: .milliseconds(50))
        // The old queue still holds its window: the new one has not begun.
        #expect(await second.windows.isEmpty)
        #expect(cleaned.withLock { $0 }.count == 1)
        await first.release()
        await lifecycle.resuming?.value
        #expect(cleaned.withLock { $0 }.count == 2)
        #expect(await wait(next, id, until: finished).last == .done)
        #expect(await wait(next, other, until: finished).last == .done)
        // From 0: only the new 20 s recording; the old one goes on from its last window.
        #expect(await second.windows.filter { $0.start == 0 }.count == 1)
        let found = try #require(fixture.transcript(id)).segments.flatMap { $0.words ?? [] }
        #expect(found.map(\.text) == script.map(\.text))
    }

    @Test func stitcherKeepsWordsByTheMiddleOfTheOverlap() {
        var stitcher = WindowStitcher()
        let edge = TimedWord(start: 58.5, end: 59, text: " edge")
        // Both windows hear the word at the edge; the cut is at 60, the overlap 58…60.
        stitcher.add(TimedTranscript(segments: [TimedSegment(start: 58.5, end: 59, text: "edge", words: [edge])]),
                     offset: 0, keepUntil: 59)
        stitcher.add(TimedTranscript(segments: [TimedSegment(start: 0.5, end: 1, text: "edge",
                                                             words: [edge.shifted(by: -58)])]),
                     offset: 58, keepUntil: nil)
        #expect(stitcher.words == [edge])
        // A phrase without word timings is kept by its start.
        var phrases = WindowStitcher()
        phrases.add(TimedTranscript(segments: [TimedSegment(start: 59.5, end: 61, text: "x")]), offset: 0, keepUntil: 59)
        phrases.add(TimedTranscript(segments: [TimedSegment(start: 1.5, end: 3, text: "x")]), offset: 58, keepUntil: nil)
        #expect(phrases.transcript(language: nil).segments.map(\.start) == [59.5])
    }

    /// Windows with words, then one without (Whisper's empty words): its
    /// first phrase starts at the window's 0, before `keepFrom`. It is kept,
    /// and the words of the window before that it covers go.
    @Test func wordlessPhraseAfterWordsIsKeptWhole() {
        var stitcher = WindowStitcher()
        let early = TimedWord(start: 55, end: 55.4, text: " early")
        let edge = TimedWord(start: 58.4, end: 58.8, text: " edge")
        stitcher.add(TimedTranscript(segments: [TimedSegment(start: 55, end: 58.8, text: "early edge",
                                                             words: [early, edge])]),
                     offset: 0, keepUntil: 59)
        // The next window from 58 s: one phrase from its 0, words unknown.
        stitcher.add(TimedTranscript(segments: [TimedSegment(start: 0, end: 4, text: "edge and more")]),
                     offset: 58, keepUntil: nil)
        let text = stitcher.transcript(language: nil).segments.map(\.text)
        #expect(text == ["early", "edge and more"])
    }

    @Test func phrasesEndAtSentencesAndPauses() {
        let words = [
            TimedWord(start: 0, end: 0.3, text: " Hello."), TimedWord(start: 0.4, end: 0.7, text: " How"),
            TimedWord(start: 0.8, end: 1, text: " are"), TimedWord(start: 2.5, end: 2.8, text: " you"),
        ]
        #expect(PhraseSplitter.split(words).map(\.text) == ["Hello.", "How are", "you"])
        let long = (0..<60).map { TimedWord(start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4, text: " a") }
        #expect(PhraseSplitter.split(long).allSatisfy { $0.end - $0.start <= PhraseSplitter.longest })
    }

    @Test func windowCut() {
        let chunk = VoiceActivity.chunk
        // The longest quiet run wins; its middle is the cut.
        #expect(WindowCut.cut(probabilities: [0.9, 0.1, 0.9, 0.1, 0.1, 0.9], tailStart: 0) == 3 * chunk + chunk)
        // No quiet chunk: the quietest one.
        #expect(WindowCut.cut(probabilities: [0.9, 0.6, 0.8], tailStart: 100) == 100 + chunk + chunk / 2)
    }
}
