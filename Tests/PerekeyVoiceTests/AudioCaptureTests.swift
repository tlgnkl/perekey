// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
@testable import PerekeyVoice
import Testing

/// A microphone without hardware: records what AudioCapture asks of it and
/// pushes blocks when the test says.
private final class FakeInput: AudioInput, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var _log: [String] = []
    private var deliver: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?
    private var changed: (@Sendable () -> Void)?
    var isAuthorized = true
    var available: Set<String> = ["built-in", "usb"]
    var failStarts = 0
    var startDelay: TimeInterval = 0

    var log: [String] { lock.withLockUnchecked { _log } }

    private func record(_ entry: String) {
        lock.withLockUnchecked { _log.append(entry) }
    }

    func isAvailable(uid: String) -> Bool { available.contains(uid) }

    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               configurationChanged: @escaping @Sendable () -> Void) throws -> Microphone? {
        record("start \(deviceUID ?? "system")")
        Thread.sleep(forTimeInterval: startDelay)
        if failStarts > 0 {
            failStarts -= 1
            record("failed")
            throw AudioCaptureError.engine("fake")
        }
        lock.withLockUnchecked {
            self.deliver = deliver
            changed = configurationChanged
        }
        record("started")
        return Microphone(id: 1, uid: deviceUID ?? "built-in", name: deviceUID ?? "built-in")
    }

    func stop() {
        lock.withLockUnchecked {
            deliver = nil
        }
        record("stop")
    }

    func discard() {
        record("discard")
    }

    /// The engine's tap: a block, if the engine runs.
    func push(_ samples: [Float], hostTime: UInt64 = 1) {
        let deliver = lock.withLockUnchecked { self.deliver }
        samples.withUnsafeBufferPointer { deliver?($0, hostTime) }
    }

    /// AVAudioEngineConfigurationChange of the engine started last.
    func configurationChange() {
        lock.withLockUnchecked { changed }?()
    }
}

private final class Collector: AudioSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (samples: [Float](), reasons: [AudioCaptureInterruption]()))

    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        state.withLockUnchecked { $0.samples += samples }
    }

    func captureInterrupted(_ reason: AudioCaptureInterruption) {
        state.withLock { $0.reasons.append(reason) }
    }

    var samples: [Float] { state.withLock { $0.samples } }
    var reasons: [AudioCaptureInterruption] { state.withLock { $0.reasons } }
}

/// Waits for work the actor started from a notification (a Task of its own).
private func settle(_ capture: AudioCapture) async {
    for _ in 0..<50 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    _ = await capture.isRunning
}

struct AudioCaptureTests {
    @Test func theMicrophoneRunsWhileAnySubscriberIs() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let dictation = try await capture.subscribe(Collector())
        let call = try await capture.subscribe(Collector())
        #expect(input.log == ["start system", "started"])
        await capture.unsubscribe(dictation)
        #expect(await capture.isRunning)
        await capture.unsubscribe(call)
        #expect(await !capture.isRunning)
        #expect(input.log == ["start system", "started", "stop"])
        await capture.unsubscribe(call) // twice is harmless
        #expect(input.log.count == 3)
    }

    @Test func blocksGoToEverySubscriberUntilItLeaves() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let a = Collector(), b = Collector()
        let tokenA = try await capture.subscribe(a)
        _ = try await capture.subscribe(b)
        input.push([1, 2])
        await capture.unsubscribe(tokenA)
        input.push([3])
        #expect(a.samples == [1, 2])
        #expect(b.samples == [1, 2, 3])
    }

    @Test func withoutAccessNothingStarts() async {
        let input = FakeInput()
        input.isAuthorized = false
        let capture = AudioCapture(input: input)
        await #expect(throws: AudioCaptureError.notAuthorized) { try await capture.subscribe(Collector()) }
        #expect(input.log.isEmpty)
        #expect(await capture.subscriberCount == 0)
    }

    @Test func aFailedStartAddsNoSubscriber() async throws {
        let input = FakeInput()
        input.failStarts = 1
        let capture = AudioCapture(input: input)
        await #expect(throws: AudioCaptureError.self) { try await capture.subscribe(Collector()) }
        #expect(await capture.subscriberCount == 0)
        #expect(await !capture.isRunning)
        _ = try await capture.subscribe(Collector())
        #expect(await capture.isRunning)
    }

    /// The "starting" state of a session: a stop that comes while the
    /// microphone starts runs after the start, so the microphone is not left on.
    @Test func anUnsubscribeDuringTheStartRunsAfterIt() async throws {
        let input = FakeInput()
        input.startDelay = 0.15
        let capture = AudioCapture(input: input)
        let starting = Task { try await capture.subscribe(Collector()) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(input.log == ["start system"]) // still starting
        await capture.unsubscribe(AudioSubscription(id: 1))
        let token = try await starting.value
        #expect(token == AudioSubscription(id: 1))
        #expect(input.log == ["start system", "started", "stop"])
        #expect(await !capture.isRunning)
    }

    @Test func aConfigurationChangeRestartsAndTellsSubscribers() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        input.configurationChange()
        await settle(capture)
        #expect(sink.reasons == [.configurationChange])
        #expect(input.log == ["start system", "started", "discard", "stop", "start system", "started"])
        #expect(await capture.isRunning)
    }

    @Test func aLostMicrophoneFallsBackToTheSystemOne() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, preferredUID: "usb")
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        input.available.remove("usb")
        input.configurationChange()
        await settle(capture)
        #expect(sink.reasons == [.deviceLost])
        #expect(input.log.last(where: { $0.hasPrefix("start ") }) == "start system")
        #expect(await capture.activeDevice?.uid == "built-in")
        #expect(await capture.preferredUID == "usb") // used again once it is back
    }

    @Test func aConfigurationChangeOfAStoppedEngineIsIgnored() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let token = try await capture.subscribe(Collector())
        await capture.unsubscribe(token)
        input.configurationChange()
        await settle(capture)
        #expect(input.log == ["start system", "started", "stop"])
    }

    @Test func selectingAMicrophoneSwitchesARunningCapture() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        await capture.selectMicrophone(uid: "usb") // idle: only remembered
        #expect(input.log == ["discard"])
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        await capture.selectMicrophone(uid: nil)
        #expect(sink.reasons == [.deviceChanged])
        #expect(input.log == ["discard", "start usb", "started", "discard", "stop", "start system", "started"])
    }

    @Test func aFailedRestartTurnsTheMicrophoneOff() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let sink = Collector()
        let token = try await capture.subscribe(sink)
        input.failStarts = 1
        input.configurationChange()
        await settle(capture)
        #expect(sink.reasons == [.configurationChange, .failed("engine(\"fake\")")])
        #expect(await !capture.isRunning)
        #expect(await capture.subscriberCount == 1)
        await capture.unsubscribe(token)
        #expect(input.log.last == "failed")
    }
}

struct ResamplerTests {
    private func tone(_ frequency: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// Feeds the signal in tap-sized blocks, as the engine does.
    private func resample(_ signal: [Float], rate: Double, block: Int) throws -> [Float] {
        let resampler = try Resampler(inputRate: rate)
        var out: [Float] = []
        var i = 0
        while i < signal.count {
            let end = min(i + block, signal.count)
            signal[i..<end].withUnsafeBufferPointer { chunk in resampler.process(chunk) { out += $0 } }
            i = end
        }
        return out
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }

    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
    func aSecondBecomes16000Samples(rate: Double) throws {
        let out = try resample(tone(440, rate: rate, seconds: 1), rate: rate, block: Int(rate / 10))
        #expect(abs(out.count - 16_000) < 200)
    }

    @Test func toneKeepsItsPitchAndLevel() throws {
        let out = try resample(tone(1_000, rate: 48_000, seconds: 1), rate: 48_000, block: 4_800)
        let middle = out[2_000..<14_000] // 0.75 s past the filter's warm-up
        let frequency = Double(zeroCrossings(middle)) / 2 / 0.75
        #expect(abs(frequency - 1_000) < 5)
        #expect(abs(rms(middle) - 0.5 / 2.0.squareRoot()) < 0.01)
    }

    @Test func blockSizeDoesNotChangeTheResult() throws {
        let signal = tone(300, rate: 48_000, seconds: 0.5)
        let big = try resample(signal, rate: 48_000, block: 4_800)
        let small = try resample(signal, rate: 48_000, block: 441)
        let n = min(big.count, small.count) - 100
        let diff = zip(big[1_000..<n], small[1_000..<n]).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 1e-3)
    }

    @Test func tonesAbove8kHzAreFilteredOut() throws {
        let out = try resample(tone(12_000, rate: 48_000, seconds: 0.5), rate: 48_000, block: 4_800)
        #expect(rms(out[1_000...]) < 0.005) // below −40 dB of the 0.35 input
    }

    @Test func onlyTheFirstChannelIsTaken() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let signal = tone(500, rate: 48_000, seconds: 0.2)
        func run(voiceOn channel: Int) throws -> [Float] {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
            buffer.frameLength = AVAudioFrameCount(signal.count)
            for c in 0..<2 {
                for i in signal.indices {
                    buffer.floatChannelData![c][i] = c == channel ? signal[i] : 0
                }
            }
            var out: [Float] = []
            try Resampler(inputRate: 48_000).process(buffer) { out += $0 }
            return out
        }
        #expect(rms(try run(voiceOn: 0)[500...]) > 0.3)
        #expect(rms(try run(voiceOn: 1)[...]) == 0)
    }
}

struct DictationAudioTests {
    @Test func keepsAudioUpToTheLimitAndSaysSoOnce() {
        let hits = OSAllocatedUnfairLock(initialState: 0)
        let audio = DictationAudio(seconds: 1) { hits.withLock { $0 += 1 } }
        #expect(audio.capacity == 16_000)
        let block = [Float](repeating: 0.25, count: 6_000)
        for i in 0..<4 {
            block.withUnsafeBufferPointer { audio.receive($0, hostTime: UInt64(100 + i)) }
        }
        #expect(audio.count == 16_000)
        #expect(audio.isFull)
        #expect(hits.withLock { $0 } == 1)
        #expect(audio.samples.allSatisfy { $0 == 0.25 })
        #expect(audio.firstHostTime == 100)
        #expect(audio.seconds == 1)
    }

    @Test func remembersTheFirstGap() {
        let audio = DictationAudio(seconds: 1)
        audio.captureInterrupted(.deviceLost)
        audio.captureInterrupted(.configurationChange)
        #expect(audio.interruption == .deviceLost)
    }

    @Test func tenMinutesByDefault() {
        #expect(DictationAudio().capacity == 600 * 16_000)
    }
}

struct VoiceCheckArgumentsTests {
    @Test func noFlagStartsTheApp() {
        #expect(VoiceCheck(arguments: ["Perekey", "-NSDocumentRevisionsDebugMode", "YES"]) == nil)
    }

    @Test func readsTheCheckAndItsOptions() throws {
        let check = try #require(VoiceCheck(arguments: ["Perekey", "--voice-check", "mic", "--cycles", "10",
                                                        "--device", "BuiltInMicrophoneDevice"]))
        #expect(check.command?.name == "mic")
        #expect(check.problem == nil)
        #expect(check.options.int("cycles", default: 1000) == 10)
        #expect(check.options.string("device") == "BuiltInMicrophoneDevice")
        #expect(check.options.int("seconds", default: 3) == 3)
    }

    @Test func refusesUnknownChecksAndOptions() throws {
        #expect(try #require(VoiceCheck(arguments: ["Perekey", "--voice-check", "speakers"])).problem != nil)
        #expect(try #require(VoiceCheck(arguments: ["Perekey", "--voice-check"])).problem != nil)
        #expect(try #require(VoiceCheck(arguments: ["Perekey", "--voice-check", "devices", "--cycles", "3"])).problem
            != nil)
        #expect(try #require(VoiceCheck(arguments: ["Perekey", "--voice-check", "mic", "--cycles"])).problem != nil)
    }
}
