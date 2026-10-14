// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

private func audio(silence: Double = 0, speech: Double = 0, then tail: Double = 0) -> AudioBuffer16k {
    func samples(_ seconds: Double, _ value: Float) -> [Float] {
        Array(repeating: value, count: Int(seconds * VoiceCore.sampleRate))
    }
    return AudioBuffer16k(samples(silence, 0.001) + samples(speech, 0.5) + samples(tail, 0.001))
}

struct VoiceActivityTests {
    @Test func gate() {
        #expect(!VoiceActivity.hasSpeech([]))
        #expect(!VoiceActivity.hasSpeech([0.1, 0.49, 0.2]))
        #expect(VoiceActivity.hasSpeech([0.1, 0.5]))
        #expect(!VoiceActivity.hasSpeech([0.9, 0.1], minimumChunks: 2))
        #expect(VoiceActivity.chunkSeconds == 0.256)
    }

    @Test func silenceCountsFromTheStart() {
        var watch = SilenceWatch(limit: 30)
        var stop = watch.observe(speech: false, upTo: 29.9)
        #expect(!stop)
        stop = watch.observe(speech: false, upTo: 30)
        #expect(stop)
    }

    @Test func silenceCountsFromTheLastSpeech() {
        var watch = SilenceWatch(limit: 30)
        var stop = watch.observe(speech: true, upTo: 10)
        #expect(!stop)
        stop = watch.observe(speech: false, upTo: 39.5)
        #expect(!stop)
        stop = watch.observe(speech: true, upTo: 40)
        #expect(!stop)
        stop = watch.observe(speech: false, upTo: 69)
        #expect(!stop)
        stop = watch.observe(speech: false, upTo: 70)
        #expect(stop)
    }

    // MARK: - The steps after a recording

    @Test func speechIsRecognized() async throws {
        let engine = FakeEngine(text: "Привет, мир.")
        try await engine.prepare()
        let outcome = try await DictationRecognition.recognize(
            audio(silence: 1, speech: 1), engine: engine, detector: FakeDetector())
        #expect(outcome == .text("Привет, мир."))
        #expect(await engine.transcribed.count == 1)
    }

    @Test func noSpeechNeverReachesTheModel() async throws {
        let engine = FakeEngine(text: "Субтитры сделал DimaTorzok")
        try await engine.prepare()
        let outcome = try await DictationRecognition.recognize(audio(silence: 3), engine: engine, detector: FakeDetector())
        #expect(outcome == .noSpeech)
        #expect(await engine.transcribed.isEmpty)
    }

    @Test func emptyAudio() async throws {
        let engine = FakeEngine()
        try await engine.prepare()
        #expect(try await DictationRecognition.recognize(AudioBuffer16k([]), engine: engine, detector: nil) == .noSpeech)
    }

    @Test func aFailedDetectorLetsTheAudioThrough() async throws {
        let engine = FakeEngine(text: "привет")
        try await engine.prepare()
        let detector = FakeDetector()
        await detector.set(fails: true)
        let outcome = try await DictationRecognition.recognize(audio(silence: 1), engine: engine, detector: detector)
        #expect(outcome == .text("привет"))
    }

    @Test func madeUpTextIsDropped() async throws {
        let engine = FakeEngine(text: "Продолжение следует...")
        try await engine.prepare()
        let outcome = try await DictationRecognition.recognize(audio(speech: 1), engine: engine, detector: FakeDetector())
        #expect(outcome == .nothingLeft)
    }

    @Test func madeUpTailIsCut() async throws {
        let engine = FakeEngine(text: "Купи хлеб. Субтитры сделал DimaTorzok")
        try await engine.prepare()
        let outcome = try await DictationRecognition.recognize(audio(speech: 1), engine: engine, detector: nil)
        #expect(outcome == .text("Купи хлеб."))
    }

    @Test func unpreparedEngineThrows() async {
        await #expect(throws: SpeechEngineError.notPrepared) {
            try await DictationRecognition.recognize(audio(speech: 1), engine: FakeEngine(), detector: nil)
        }
    }

    @Test func engineWithoutTimingsCannotTranscribeFiles() async {
        await #expect(throws: SpeechEngineError.unsupported) {
            try await FakeEngine().transcribeTimed(AudioBuffer16k([0]), language: nil)
        }
    }
}
