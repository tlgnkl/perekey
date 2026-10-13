// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
@testable import PerekeyVoice
import Testing

/// A microphone without hardware: records what AudioCapture asks of it and
/// pushes blocks when the test says. Its stop delivers a one-sample tail, as
/// the converter's flush does.
private final class FakeInput: AudioInput, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var _log: [String] = []
    private var deliver: (@Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void)?
    private var event: (@Sendable (AudioInputEvent) -> Void)?
    var isAuthorized = true
    var available: Set<String> = ["built-in", "usb"]
    var failStarts = 0
    var startDelay: TimeInterval = 0
    var tail: Float = -1

    var log: [String] { lock.withLockUnchecked { _log } }

    private func record(_ entry: String) {
        lock.withLockUnchecked { _log.append(entry) }
    }

    func isAvailable(uid: String) -> Bool { available.contains(uid) }

    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               event: @escaping @Sendable (AudioInputEvent) -> Void) throws -> Microphone? {
        record("start \(deviceUID ?? "system")")
        Thread.sleep(forTimeInterval: startDelay)
        if failStarts > 0 {
            failStarts -= 1
            record("failed")
            throw AudioCaptureError.engine("fake")
        }
        lock.withLockUnchecked {
            self.deliver = deliver
            self.event = event
        }
        record("started")
        return Microphone(id: 1, uid: deviceUID ?? "built-in", name: deviceUID ?? "built-in")
    }

    func stop() {
        let deliver = lock.withLockUnchecked {
            defer { self.deliver = nil }
            return self.deliver
        }
        [tail].withUnsafeBufferPointer { deliver?($0, 0) }
        record("stop")
    }

    /// The engine's tap: a block, if the engine runs.
    func push(_ samples: [Float], hostTime: UInt64 = 1) {
        let deliver = lock.withLockUnchecked { self.deliver }
        samples.withUnsafeBufferPointer { deliver?($0, hostTime) }
    }

    /// An event of the engine started last.
    func send(_ event: AudioInputEvent) {
        lock.withLockUnchecked { self.event }?(event)
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

    /// What the microphone gave, without the tails of stops.
    var samples: [Float] { state.withLock { $0.samples.filter { $0 >= 0 } } }
    var tails: Int { state.withLock { $0.samples.filter { $0 < 0 }.count } }
    var reasons: [AudioCaptureInterruption] { state.withLock { $0.reasons } }
}

/// Waits for work the actor started from an event (a Task of its own).
private func settle(_ capture: AudioCapture, for duration: Duration = .milliseconds(100)) async {
    let clock = ContinuousClock()
    let end = clock.now + duration
    while clock.now < end {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    _ = await capture.isRunning
}

/// Waits until `condition` holds, at most two seconds: timing tests then pass
/// on a busy machine too.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + .seconds(2)
    while clock.now < end {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
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
        let tokenB = try await capture.subscribe(b)
        input.push([1, 2])
        await capture.unsubscribe(tokenA)
        input.push([3])
        #expect(a.samples == [1, 2])
        #expect(b.samples == [1, 2, 3])
        // The last one also gets the converter's tail; one that left earlier does not.
        await capture.unsubscribe(tokenB)
        #expect(b.tails == 1)
        #expect(a.tails == 0)
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
        // Long enough to see the start under the load of the whole suite.
        input.startDelay = 1
        let capture = AudioCapture(input: input)
        let starting = Task { try await capture.subscribe(Collector()) }
        #expect(await eventually { input.log == ["start system"] }) // still starting
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
        input.send(.configurationChange)
        await settle(capture)
        #expect(sink.reasons == [.configurationChange])
        #expect(sink.tails == 1) // the audio up to the gap
        #expect(input.log == ["start system", "started", "stop", "start system", "started"])
        #expect(await capture.isRunning)
    }

    @Test func aLostMicrophoneFallsBackToTheSystemOne() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, preferredUID: "usb")
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        input.available.remove("usb")
        input.send(.configurationChange)
        await settle(capture)
        #expect(sink.reasons == [.deviceLost])
        #expect(input.log.last(where: { $0.hasPrefix("start ") }) == "start system")
        #expect(await capture.activeDevice?.uid == "built-in")
        #expect(await capture.preferredUID == "usb") // used again once it is back
    }

    /// A device can die without a configuration change; its IsAlive listener
    /// tells.
    @Test func aDeadDeviceRestartsAsLost() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, preferredUID: "usb")
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        input.available.remove("usb")
        input.send(.deviceDied)
        await settle(capture)
        #expect(sink.reasons == [.deviceLost])
        #expect(input.log == ["start usb", "started", "stop", "start system", "started"])
    }

    @Test func anEventOfAStoppedEngineIsIgnored() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let token = try await capture.subscribe(Collector())
        await capture.unsubscribe(token)
        input.send(.configurationChange)
        input.send(.deviceDied)
        await settle(capture)
        #expect(input.log == ["start system", "started", "stop"])
    }

    @Test func selectingAMicrophoneSwitchesARunningCapture() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        await capture.selectMicrophone(uid: "usb") // idle: only remembered
        #expect(input.log.isEmpty)
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        await capture.selectMicrophone(uid: nil)
        #expect(sink.reasons == [.deviceChanged])
        #expect(input.log == ["start usb", "started", "stop", "start system", "started"])
    }

    /// After `.failed` the subscribers are gone: a later subscribe does not
    /// wake them up behind their back.
    @Test func aFailedRestartRemovesTheSubscribers() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input)
        let old = Collector()
        let token = try await capture.subscribe(old)
        input.failStarts = 1
        input.send(.configurationChange)
        await settle(capture)
        #expect(old.reasons == [.configurationChange, .failed("engine(\"fake\")")])
        #expect(await !capture.isRunning)
        #expect(await capture.subscriberCount == 0)
        await capture.unsubscribe(token) // harmless
        _ = try await capture.subscribe(Collector())
        input.push([5])
        #expect(old.samples.isEmpty)
    }

    @Test func blocksKeepTheWatchdogQuiet() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, stallTimeout: .milliseconds(200), firstBlockTimeout: .milliseconds(200))
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        for _ in 0..<40 {
            input.push([0])
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sink.reasons.isEmpty)
        #expect(input.log == ["start system", "started"])
    }

    /// No blocks from a running engine: restart once, then give up.
    @Test func aStalledEngineRestartsOnceThenFails() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, stallTimeout: .milliseconds(80), firstBlockTimeout: .milliseconds(80))
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        #expect(await eventually { !sink.reasons.isEmpty })
        #expect(sink.reasons == [.stalled])
        #expect(await capture.isRunning)
        #expect(await eventually { sink.reasons.count == 2 })
        #expect(sink.reasons.last == .failed("no audio from built-in"))
        #expect(await !capture.isRunning)
        #expect(await capture.subscriberCount == 0)
    }

    /// A stall, then audio again: the next stall restarts once more instead of failing.
    @Test func audioAfterAStallResetsTheWatchdog() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, stallTimeout: .milliseconds(80), firstBlockTimeout: .milliseconds(80))
        let sink = Collector()
        _ = try await capture.subscribe(sink)
        #expect(await eventually { !sink.reasons.isEmpty })
        input.push([0])
        #expect(await eventually { sink.reasons.count >= 2 })
        #expect(sink.reasons.prefix(2) == [.stalled, .stalled])
    }

    /// A headset switching to its microphone profile is slow to give its first
    /// buffers: the watchdog waits longer for the first block than between blocks.
    @Test func theFirstBlockMayTakeLonger() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, stallTimeout: .milliseconds(60), firstBlockTimeout: .milliseconds(400))
        let sink = Collector()
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await capture.subscribe(sink)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.reasons.isEmpty)
        input.push([0]) // the first block, late
        #expect(await eventually { !sink.reasons.isEmpty })
        #expect(sink.reasons == [.stalled])
        #expect(clock.now - started >= .milliseconds(400))
    }

    /// A stall whose restart fails, then a new subscriber: its first stall
    /// restarts again instead of failing at once on the old count.
    @Test func aNewSessionStartsWithACleanWatchdog() async throws {
        let input = FakeInput()
        let capture = AudioCapture(input: input, stallTimeout: .milliseconds(50), firstBlockTimeout: .milliseconds(50))
        let first = Collector()
        _ = try await capture.subscribe(first)
        input.failStarts = 1
        #expect(await eventually { first.reasons.count == 2 })
        #expect(first.reasons == [.stalled, .failed("engine(\"fake\")")])
        let second = Collector()
        _ = try await capture.subscribe(second)
        #expect(await eventually { !second.reasons.isEmpty })
        #expect(second.reasons.first == .stalled)
    }
}

struct ResamplerTests {
    private func tone(_ frequency: Double, rate: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private struct Block {
        var samples: [Float]
        var hostTime: UInt64
    }

    /// Feeds the signal in tap-sized blocks, as the engine does, each stamped
    /// with its host time from `start`; with `finish`, flushes at the end.
    private func blocks(_ signal: [Float], rate: Double, block: Int, start: UInt64 = 1_000_000,
                        finish: Bool = false) throws -> (blocks: [Block], inputTimes: [UInt64]) {
        let resampler = try Resampler(inputRate: rate)
        var out: [Block] = []
        var inputTimes: [UInt64] = []
        var i = 0
        while i < signal.count {
            let end = min(i + block, signal.count)
            let time = start + HostTime.ticks(Double(i) / rate)
            signal[i..<end].withUnsafeBufferPointer { chunk in
                resampler.process(chunk, hostTime: time) { out.append(Block(samples: Array($0), hostTime: $1)) }
            }
            inputTimes.append(time)
            i = end
        }
        if finish {
            resampler.finish { out.append(Block(samples: Array($0), hostTime: $1)) }
        }
        return (out, inputTimes)
    }

    private func resample(_ signal: [Float], rate: Double, block: Int, finish: Bool = false) throws -> [Float] {
        try blocks(signal, rate: rate, block: block, finish: finish).blocks.flatMap(\.samples)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }

    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    @Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
    func aSecondBecomes16000Samples(rate: Double) throws {
        let out = try resample(tone(440, rate: rate, seconds: 1), rate: rate, block: Int(rate / 10), finish: true)
        #expect(abs(out.count - 16_000) <= 2)
    }

    @Test func finishFlushesWhatTheConverterHolds() throws {
        let signal = tone(440, rate: 48_000, seconds: 1)
        let held = try resample(signal, rate: 48_000, block: 4_800)
        let flushed = try resample(signal, rate: 48_000, block: 4_800, finish: true)
        #expect(flushed.count > held.count)
        #expect(abs(flushed.count - 16_000) <= 2)
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
            try Resampler(inputRate: 48_000).process(buffer, hostTime: 1) { samples, _ in out += samples }
            return out
        }
        #expect(rms(try run(voiceOn: 0)[500...]) > 0.3)
        #expect(rms(try run(voiceOn: 1)[...]) == 0)
    }

    /// Each block is stamped from the input buffer it came out with: with
    /// exact input times the blocks follow each other without gap or overlap.
    @Test(arguments: [48_000.0, 44_100.0])
    func stampsLineUpBlockAfterBlock(rate: Double) throws {
        let (out, inputTimes) = try blocks(tone(440, rate: rate, seconds: 1), rate: rate, block: Int(rate / 10))
        #expect(out.count == inputTimes.count)
        #expect(out[0].hostTime == inputTimes[0])
        let tick = 1 / HostTime.ticksPerSecond
        for (a, b) in zip(out, out.dropFirst()) {
            let end = Double(a.hostTime) * tick + Double(a.samples.count) / 16_000
            #expect(abs(Double(b.hostTime) * tick - end) < 0.000_1)
        }
    }

    /// A click comes out at the time it went in, by the stamps. The input's
    /// clock runs 0.1 % fast against the host here: a count of samples from
    /// the start would put the click 0.5 ms off, the anchor on each buffer
    /// does not.
    @Test(arguments: [1.0, 1.001])
    func aClickKeepsItsHostTime(clockRatio: Double) throws {
        let rate = 48_000.0
        var signal = [Float](repeating: 0, count: Int(rate))
        let click = 24_000 + 150
        signal[click] = 1
        let start: UInt64 = 1_000_000
        let resampler = try Resampler(inputRate: rate)
        var best = (value: Float(0), time: 0.0)
        let tick = 1 / HostTime.ticksPerSecond
        for i in stride(from: 0, to: signal.count, by: 4_800) {
            let time = start + HostTime.ticks(Double(i) / rate * clockRatio)
            signal[i..<(i + 4_800)].withUnsafeBufferPointer { chunk in
                resampler.process(chunk, hostTime: time) { samples, stamp in
                    for (k, sample) in samples.enumerated() where abs(sample) > best.value {
                        best = (abs(sample), Double(stamp - start) * tick + Double(k) / 16_000)
                    }
                }
            }
        }
        let truth = Double(click) / rate * clockRatio
        #expect(abs(best.time - truth) < 0.000_1)
    }

    /// The whole second in one call, and in calls of 100 frames: the
    /// converter is drained each time, nothing stays behind.
    @Test(arguments: [100, 48_000])
    func anyBlockSizeGivesItAll(block: Int) throws {
        let out = try resample(tone(440, rate: 48_000, seconds: 1), rate: 48_000, block: block, finish: true)
        #expect(abs(out.count - 16_000) <= 2)
    }

    /// Input too short for any output: the flushed tail is stamped from the
    /// input's host time, not from zero.
    @Test func aTailAloneKeepsTheInputTime() throws {
        let resampler = try Resampler(inputRate: 48_000)
        let hostTime: UInt64 = 5_000_000_000
        var stamps: [UInt64] = []
        tone(440, rate: 48_000, seconds: 0.002).withUnsafeBufferPointer {
            resampler.process($0, hostTime: hostTime) { _, stamp in stamps.append(stamp) }
        }
        resampler.finish { _, stamp in stamps.append(stamp) }
        #expect(!stamps.isEmpty)
        let offset = abs(Double(Int64(stamps[0]) - Int64(hostTime))) / HostTime.ticksPerSecond
        #expect(offset < 0.001)
    }

    /// A clock that jumps back (a host time earlier than the last block's end)
    /// never moves a stamp back.
    @Test func stampsNeverGoBack() throws {
        let resampler = try Resampler(inputRate: 48_000)
        let chunk = tone(440, rate: 48_000, seconds: 0.1)
        var stamps: [UInt64] = []
        for time: UInt64 in [10_000_000, 20_000_000, 5_000_000] {
            chunk.withUnsafeBufferPointer { resampler.process($0, hostTime: time) { _, stamp in stamps.append(stamp) } }
        }
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 < $1 })
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
        // onLimit runs on a queue of its own, not under the delivery lock.
        for _ in 0..<200 where hits.withLock({ $0 }) == 0 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        Thread.sleep(forTimeInterval: 0.02)
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
