// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AudioToolbox
import CoreAudio
import os
import PerekeyVoiceCore

/// Receives the microphone's audio: 16 kHz mono Float32, the rate of the speech
/// models. Both calls come one at a time, under the lock that `AudioCapture`
/// takes to add and remove subscribers: the capture thread waits for the sink,
/// and so does `unsubscribe`. So a sink only copies what it keeps and hands any
/// other work to a `Task` or a queue of its own. It never waits for
/// `AudioCapture` or for work that does: that deadlocks.
public protocol AudioSink: AnyObject, Sendable {
    /// `samples` is valid only during the call. `hostTime` is when the block's
    /// first sample was heard, in `mach_absolute_time` units: the `mHostTime`
    /// of the input buffer it came out with, less what the converter held back
    /// before it. Times only go forward.
    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64)
    /// The audio has a gap. Unless the reason is `.failed`, capture goes on.
    func captureInterrupted(_ reason: AudioCaptureInterruption)
}

extension AudioSink {
    public func captureInterrupted(_ reason: AudioCaptureInterruption) {}
}

public enum AudioCaptureInterruption: Sendable, Equatable {
    /// `AVAudioEngineConfigurationChange`: the device's format or the system
    /// input changed, and the engine stopped. Capture restarted.
    case configurationChange
    /// The microphone went away, with or without a configuration change.
    /// Capture restarted on the system one, or on the chosen one if it is back.
    case deviceLost
    /// No audio came while the engine ran: a device can stop without telling.
    /// Capture restarted.
    case stalled
    /// `selectMicrophone` switched the device while capture ran.
    case deviceChanged
    /// The engine did not start again, or stalled twice in a row: the
    /// microphone is off, and every subscriber was removed. Subscribing again
    /// tries again.
    case failed(String)
}

public enum AudioCaptureError: Error, Equatable {
    case notAuthorized
    case noInputDevice
    case engine(String)
}

/// A subscriber's place in `AudioCapture`; `unsubscribe` takes it back.
public struct AudioSubscription: Hashable, Sendable {
    let id: UInt64

    /// For other sources of dictation audio (`DictationMicrophone`): files,
    /// tests. `AudioCapture` ignores a token it did not give.
    public init(id: UInt64) {
        self.id = id
    }
}

/// The microphone permission (TCC). macOS ties it to the app's signature.
public enum MicrophoneAccess {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Shows the macOS prompt the first time; later returns the answer given.
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// The one owner of the microphone and its `AVAudioEngine`. Starting and
/// stopping the engine, its tap, the device switch and
/// `AVAudioEngineConfigurationChange` all go through this actor.
///
/// The microphone runs while there is at least one subscriber: dictation keeps
/// blocks in memory (`DictationAudio`), a call recording writes to disk. They
/// share one device. The actor runs on its own serial queue, and `subscribe`
/// starts the engine within the call, so an `unsubscribe` sent while the
/// microphone starts runs after the start is done.
public actor AudioCapture {
    private let queue = DispatchSerialQueue(label: "app.perekey.audio-capture", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let input: any AudioInput
    private let sinks = SinkRegistry()
    private var nextID: UInt64 = 0
    /// Bumped on each start: an event of an engine already gone is ignored.
    private var generation = 0
    /// How long a running engine may give no audio before it counts as stalled.
    private let stallTimeout: Duration
    /// The same before its first block: Bluetooth headsets switching to their
    /// microphone profile give the first buffers only after 1–2 s.
    private let firstBlockTimeout: Duration
    private var watchdog: Task<Void, Never>?
    /// The watchdog's wait. Tests move its time themselves.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The block count when a stall last restarted the engine: no block since
    /// then means the new engine stalled too.
    private var blocksAtStall: Int?
    /// The microphone the user chose; nil follows the system one.
    public private(set) var preferredUID: String?
    /// The device the running engine reads, nil while the microphone is off.
    public private(set) var activeDevice: Microphone?
    public private(set) var isRunning = false

    public init(preferredUID: String? = nil) {
        self.init(input: EngineInput(), preferredUID: preferredUID)
    }

    init(input: any AudioInput, preferredUID: String? = nil, stallTimeout: Duration = .milliseconds(1500),
         firstBlockTimeout: Duration = .seconds(4),
         sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep) {
        self.input = input
        self.preferredUID = preferredUID
        self.stallTimeout = stallTimeout
        self.firstBlockTimeout = firstBlockTimeout
        self.sleep = sleep
    }

    /// Adds a subscriber and starts the microphone if it is the first. Throws,
    /// adding nothing, if the microphone does not start.
    public func subscribe(_ sink: any AudioSink) throws -> AudioSubscription {
        guard input.isAuthorized else { throw AudioCaptureError.notAuthorized }
        nextID += 1
        let token = AudioSubscription(id: nextID)
        sinks.add(sink, id: token.id)
        if !isRunning {
            blocksAtStall = nil
            do {
                try start()
            } catch {
                sinks.remove(id: token.id)
                throw error
            }
        }
        return token
    }

    /// Removes a subscriber; the last one turns the microphone off and still
    /// gets the converter's last milliseconds. After it returns, the sink gets
    /// nothing more.
    public func unsubscribe(_ token: AudioSubscription) {
        guard sinks.contains(id: token.id) else { return }
        if sinks.count == 1, isRunning {
            stop()
            blocksAtStall = nil
        }
        sinks.remove(id: token.id)
    }

    public var subscriberCount: Int { sinks.count }

    /// While a call is recorded, the microphone of the settings does not
    /// switch: a choice made meanwhile applies once the last hold ends.
    private var holds = 0
    private var heldChoice: String??

    public func holdMicrophone() {
        holds += 1
    }

    public func releaseMicrophone() {
        holds = max(0, holds - 1)
        guard holds == 0, let choice = heldChoice else { return }
        heldChoice = nil
        selectMicrophone(uid: choice)
    }

    /// Chooses the microphone by UID, nil for the system one. While capture
    /// runs, it switches at once and subscribers see `.deviceChanged`; callers
    /// that apply settings only after "Stop" call this then.
    public func selectMicrophone(uid: String?) {
        if holds > 0 {
            heldChoice = .some(uid)
            return
        }
        guard uid != preferredUID else { return }
        preferredUID = uid
        if isRunning {
            restart(after: .deviceChanged)
        }
    }

    private func start() throws {
        var uid = preferredUID
        if let wanted = uid, !input.isAvailable(uid: wanted) {
            uid = nil // gone: the system microphone until the chosen one is back
        }
        generation += 1
        let current = generation
        let sinks = self.sinks
        activeDevice = try input.start(
            deviceUID: uid,
            deliver: { samples, hostTime in sinks.deliver(samples, hostTime: hostTime) },
            event: { [weak self] event in
                Task { await self?.handle(event, generation: current) }
            })
        isRunning = true
        watch(generation: current)
    }

    /// Stops the engine; the converter's tail still goes to the subscribers.
    private func stop() {
        watchdog?.cancel()
        watchdog = nil
        input.stop()
        isRunning = false
        activeDevice = nil
    }

    private func handle(_ event: AudioInputEvent, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        switch event {
        case .deviceDied:
            restart(after: .deviceLost)
        case .configurationChange:
            let lost = preferredUID.map { !input.isAvailable(uid: $0) } ?? false
            restart(after: lost && activeDevice?.uid == preferredUID ? .deviceLost : .configurationChange)
        }
    }

    /// A device can stop giving audio with neither a configuration change nor
    /// a word from CoreAudio. A running engine always gives blocks, silence
    /// too, so none for `stallTimeout` (`firstBlockTimeout` before the first)
    /// means it stalled: restart once, and give up if the new engine stalls
    /// as well.
    private func watch(generation: Int) {
        let timeout = stallTimeout
        let firstTimeout = firstBlockTimeout
        let sinks = self.sinks
        let sleep = self.sleep
        watchdog = Task { [weak self] in
            var seen = sinks.blockCount
            var heard = false
            while !Task.isCancelled {
                try? await sleep(heard ? timeout : firstTimeout)
                let blocks = sinks.blockCount
                if blocks != seen {
                    seen = blocks
                    heard = true
                    continue
                }
                await self?.stalled(generation: generation)
                return
            }
        }
    }

    private func stalled(generation: Int) {
        guard generation == self.generation, isRunning else { return }
        if let before = blocksAtStall, before == sinks.blockCount {
            fail("no audio from \(activeDevice?.name ?? "the microphone")")
            return
        }
        let lost = preferredUID.map { !input.isAvailable(uid: $0) } ?? false
        restart(after: lost ? .deviceLost : .stalled)
        if isRunning {
            blocksAtStall = sinks.blockCount // after the stop's tail, which is no new audio
        }
    }

    private func restart(after reason: AudioCaptureInterruption) {
        stop()
        sinks.notify(reason)
        guard !sinks.isEmpty else { return }
        do {
            try start()
        } catch {
            fail(String(describing: error))
        }
    }

    /// The microphone stays off: subscribers learn why and are removed, so the
    /// next `subscribe` does not wake them up again.
    private func fail(_ why: String) {
        if isRunning {
            stop()
        }
        blocksAtStall = nil
        sinks.notify(.failed(why))
        sinks.removeAll()
    }
}

/// The subscribers, shared by the actor and the capture thread. Blocks are
/// delivered under the lock, so `remove` waits for a block in flight.
final class SinkRegistry: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var sinks: [(id: UInt64, sink: any AudioSink)] = []
        /// Blocks delivered so far, for the stall watchdog.
        var blocks = 0
    }

    var isEmpty: Bool { state.withLock { $0.sinks.isEmpty } }
    var count: Int { state.withLock { $0.sinks.count } }
    var blockCount: Int { state.withLock { $0.blocks } }

    func contains(id: UInt64) -> Bool {
        state.withLock { $0.sinks.contains { $0.id == id } }
    }

    func add(_ sink: any AudioSink, id: UInt64) {
        state.withLock { $0.sinks.append((id, sink)) }
    }

    func remove(id: UInt64) {
        state.withLock { $0.sinks.removeAll { $0.id == id } }
    }

    func removeAll() {
        state.withLock { $0.sinks.removeAll() }
    }

    func deliver(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        state.withLockUnchecked { state in
            state.blocks += 1
            for entry in state.sinks {
                entry.sink.receive(samples, hostTime: hostTime)
            }
        }
    }

    func notify(_ reason: AudioCaptureInterruption) {
        state.withLock { state in
            for entry in state.sinks {
                entry.sink.captureInterrupted(reason)
            }
        }
    }
}

enum AudioInputEvent: Sendable {
    /// `AVAudioEngineConfigurationChange`: the engine stopped.
    case configurationChange
    /// `kAudioDevicePropertyDeviceIsAlive` of the device read went false.
    case deviceDied
}

/// The audio device behind `AudioCapture`; tests put a fake in its place.
/// Called only on the actor's queue.
protocol AudioInput: AnyObject, Sendable {
    var isAuthorized: Bool { get }
    /// The device is there and alive.
    func isAvailable(uid: String) -> Bool
    /// Starts capture on the device, nil for the system one, and returns the
    /// device it reads. `deliver` gets 16 kHz mono blocks on the capture thread;
    /// `event` comes on any thread.
    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               event: @escaping @Sendable (AudioInputEvent) -> Void) throws -> Microphone?
    /// Stops capture and delivers what the converter still holds.
    func stop()
}

/// `AVAudioEngine` on the device's own rate. Asking the input for 16 kHz gives
/// silence, so the tap takes the native format and `Resampler` converts.
///
/// Each start builds a new engine and stop drops it. A stopped engine misses
/// what changed meanwhile, such as the device's rate, and its tap would then
/// get buffers of a format it was not set up for.
final class EngineInput: AudioInput, @unchecked Sendable {
    // Touched only on AudioCapture's queue.
    private var running: Running?
    private let listenerQueue = DispatchQueue(label: "app.perekey.audio-capture.device")

    private struct Running {
        let engine: AVAudioEngine
        let resampler: Resampler
        let deliver: @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void
        let observer: any NSObjectProtocol
        let device: AudioDeviceID
        let aliveListener: AudioObjectPropertyListenerBlock
    }

    var isAuthorized: Bool { MicrophoneAccess.status == .authorized }

    func isAvailable(uid: String) -> Bool {
        MicrophoneList.device(uid: uid).map { MicrophoneList.isAlive($0.id) } ?? false
    }

    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               event: @escaping @Sendable (AudioInputEvent) -> Void) throws -> Microphone? {
        stop()
        let target = if let deviceUID { MicrophoneList.device(uid: deviceUID) } else { MicrophoneList.systemDefault() }
        guard let target else { throw AudioCaptureError.noInputDevice }
        let engine = try makeEngine(device: deviceUID == nil ? nil : target)
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        let resampler = try Resampler(inputRate: format.sampleRate)
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            // Without a time from the engine the buffer ends about now.
            let hostTime = time.isHostTimeValid ? time.hostTime
                : mach_absolute_time() - HostTime.ticks(Double(buffer.frameLength) / buffer.format.sampleRate)
            resampler.process(buffer, hostTime: hostTime, deliver)
        }
        // Both listeners are in place before the engine starts: a change during
        // the start is not missed.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in event(.configurationChange) }
        let device = currentDevice(of: node) ?? target
        let aliveListener: AudioObjectPropertyListenerBlock = { _, _ in
            if !MicrophoneList.isAlive(device.id) {
                event(.deviceDied)
            }
        }
        var alive = MicrophoneList.address(kAudioDevicePropertyDeviceIsAlive)
        AudioObjectAddPropertyListenerBlock(device.id, &alive, listenerQueue, aliveListener)
        running = Running(engine: engine, resampler: resampler, deliver: deliver, observer: observer,
                          device: device.id, aliveListener: aliveListener)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw AudioCaptureError.engine(String(describing: error))
        }
        return device
    }

    func stop() {
        guard let running else { return }
        self.running = nil
        NotificationCenter.default.removeObserver(running.observer)
        var alive = MicrophoneList.address(kAudioDevicePropertyDeviceIsAlive)
        AudioObjectRemovePropertyListenerBlock(running.device, &alive, listenerQueue, running.aliveListener)
        running.engine.inputNode.removeTap(onBus: 0)
        running.engine.stop()
        running.resampler.finish(running.deliver)
    }

    /// A new engine reading the device, nil for the system one. The device is
    /// set on the AUHAL of the input node before the engine reads its format.
    private func makeEngine(device: Microphone?) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard let device else { return engine }
        guard let unit = engine.inputNode.audioUnit else { throw AudioCaptureError.noInputDevice }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AudioCaptureError.engine("kAudioOutputUnitProperty_CurrentDevice: \(status)")
        }
        return engine
    }

    private func currentDevice(of node: AVAudioInputNode) -> Microphone? {
        guard let unit = node.audioUnit else { return nil }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &id, &size) == noErr else { return nil }
        return MicrophoneList.all().first { $0.id == id }
    }
}

/// Host time (`mach_absolute_time`) in seconds and back.
enum HostTime {
    static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }()

    static func ticks(_ seconds: Double) -> UInt64 {
        UInt64((seconds * ticksPerSecond).rounded())
    }
}

/// Converts the input to 16 kHz mono Float32. Takes the first channel only:
/// averaging the channels of a mic array or an interface can thin out or
/// cancel the voice. The tap converts and `finish` flushes, so a lock keeps
/// them apart.
///
/// Each output block is stamped from the `mHostTime` of the input buffer just
/// given, moved back by what the converter still held before it: input given
/// so far, at 16 kHz, less output taken. That backlog is not constant: at
/// 48 kHz the converter hands out about 1365 samples per 4096 input frames
/// and keeps up to some 75 ms. Anchoring each block on the host clock,
/// instead of counting samples from the start, keeps the drift of the
/// microphone's clock out of the times, so the tracks of a call line up.
final class Resampler: @unchecked Sendable {
    let inputRate: Double
    private let lock = OSAllocatedUnfairLock()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    // Guarded by `lock`.
    private var mono: AVAudioPCMBuffer
    private var output: AVAudioPCMBuffer
    private var inputFrames = 0
    private var outputFrames = 0
    /// The host time of the last input buffer and its first frame's index.
    private var lastInput: (hostTime: UInt64, frame: Int)?
    /// The last block's stamp, which the next one passes.
    private var lastStamp: UInt64?
    private var finished = false

    init(inputRate: Double) throws {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: VoiceCore.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let mono = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1700)
        else { throw AudioCaptureError.engine("no converter from \(inputRate) Hz") }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.inputRate = inputRate
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
        self.mono = mono
        self.output = output
    }

    /// Converts the first channel of a tap buffer. A buffer of another rate
    /// is dropped: the engine posts a configuration change for it, and the
    /// next engine gets a resampler of its own.
    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64,
                 _ body: (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        guard let channels = buffer.floatChannelData, buffer.format.sampleRate == inputRate else { return }
        process(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)), hostTime: hostTime, body)
    }

    /// Converts native-rate mono samples heard from `hostTime` on. The
    /// converter keeps its filter state between calls, so a stream split into
    /// blocks converts as one.
    func process(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64,
                 _ body: (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        let frames = AVAudioFrameCount(samples.count)
        guard frames > 0 else { return }
        lock.withLockUnchecked {
            guard !finished else { return }
            if mono.frameCapacity < frames {
                guard let bigger = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
                mono = bigger
            }
            mono.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
            mono.frameLength = frames
            lastInput = (hostTime, inputFrames)
            let source = InputOnce(mono)
            inputFrames += Int(frames)
            convert(frames: frames, body) { source.next($0) }
        }
    }

    /// Flushes the samples the converter still holds, the last milliseconds
    /// before a stop. Takes no more input after it.
    func finish(_ body: (UnsafeBufferPointer<Float>, UInt64) -> Void) {
        lock.withLockUnchecked {
            guard !finished else { return }
            finished = true
            guard inputFrames > 0 else { return }
            convert(frames: 0, body) { status in
                status.pointee = .endOfStream
                return nil
            }
        }
    }

    /// When output sample `outputFrames` was heard. The converter's output
    /// starts where its input started, so it lies as far from the last input
    /// buffer's start as their sample positions do: before it while the
    /// converter holds samples back. Never before the last stamp.
    private func nextStamp() -> UInt64 {
        guard let lastInput else { return 0 }
        let offset = Double(outputFrames) / VoiceCore.sampleRate - Double(lastInput.frame) / inputRate
        let ticks = Int64((offset * HostTime.ticksPerSecond).rounded())
        let anchored = UInt64(max(0, Int64(lastInput.hostTime) + ticks))
        return lastStamp.map { max(anchored, $0 + 1) } ?? anchored
    }

    /// Converts until the converter has nothing more for now, hands each
    /// output block to `body` with its stamp. Called under `lock`.
    private func convert(frames: AVAudioFrameCount, _ body: (UnsafeBufferPointer<Float>, UInt64) -> Void,
                         input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) {
        let wanted = AVAudioFrameCount((Double(frames) * VoiceCore.sampleRate / inputRate).rounded(.up)) + 1024
        if output.frameCapacity < wanted {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: wanted) else { return }
            output = bigger
        }
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in input(outStatus) }
            let count = Int(output.frameLength)
            guard status != .error else { return }
            if count > 0 {
                let stamp = nextStamp()
                lastStamp = stamp
                outputFrames += count
                body(UnsafeBufferPointer(start: output.floatChannelData![0], count: count), stamp)
            }
            // .haveData: the output buffer filled up and more is waiting.
            guard status == .haveData, count > 0 else { return }
        }
    }

    /// Hands the converter one buffer, then says there is no more for now: the
    /// converter keeps its state for the next call instead of flushing.
    private final class InputOnce: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else {
                status.pointee = .noDataNow
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}
