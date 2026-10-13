// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AudioToolbox
import CoreAudio
import os
import PerekeyVoiceCore

/// Receives the microphone's audio: 16 kHz mono Float32, the rate of the speech
/// models. Both calls come on the capture thread, one at a time. A sink copies
/// what it keeps and returns at once: the next block waits for it, and so does
/// `AudioCapture.unsubscribe`.
public protocol AudioSink: AnyObject, Sendable {
    /// `samples` is valid only during the call. `hostTime` is the `mHostTime` of
    /// the block's first input sample (`mach_absolute_time` units).
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
    /// The chosen microphone went away. Capture restarted on the system one.
    case deviceLost
    /// `selectMicrophone` switched the device while capture ran.
    case deviceChanged
    /// The engine did not start again: the microphone is off. Subscribers stay
    /// until they unsubscribe; the next `subscribe` tries again.
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
    /// Bumped on each start: a configuration change of an engine already gone is ignored.
    private var generation = 0
    /// The microphone the user chose; nil follows the system one.
    public private(set) var preferredUID: String?
    /// The device the running engine reads, nil while the microphone is off.
    public private(set) var activeDevice: Microphone?
    public private(set) var isRunning = false

    public init(preferredUID: String? = nil) {
        self.init(input: EngineInput(), preferredUID: preferredUID)
    }

    init(input: any AudioInput, preferredUID: String? = nil) {
        self.input = input
        self.preferredUID = preferredUID
    }

    /// Adds a subscriber and starts the microphone if it is the first. Throws,
    /// adding nothing, if the microphone does not start.
    public func subscribe(_ sink: any AudioSink) throws -> AudioSubscription {
        guard input.isAuthorized else { throw AudioCaptureError.notAuthorized }
        nextID += 1
        let token = AudioSubscription(id: nextID)
        sinks.add(sink, id: token.id)
        if !isRunning {
            do {
                try start()
            } catch {
                sinks.remove(id: token.id)
                throw error
            }
        }
        return token
    }

    /// Removes a subscriber; the last one turns the microphone off. After it
    /// returns, the sink gets nothing more.
    public func unsubscribe(_ token: AudioSubscription) {
        sinks.remove(id: token.id)
        if sinks.isEmpty, isRunning {
            stop()
        }
    }

    public var subscriberCount: Int { sinks.count }

    /// Chooses the microphone by UID, nil for the system one. While capture
    /// runs, it switches at once and subscribers see `.deviceChanged`; callers
    /// that apply settings only after "Stop" call this then.
    public func selectMicrophone(uid: String?) {
        guard uid != preferredUID else { return }
        preferredUID = uid
        input.discard()
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
            configurationChanged: { [weak self] in
                Task { await self?.configurationChanged(generation: current) }
            })
        isRunning = true
    }

    private func stop() {
        input.stop()
        isRunning = false
        activeDevice = nil
    }

    private func configurationChanged(generation: Int) {
        guard generation == self.generation, isRunning else { return }
        let lost = preferredUID.map { !input.isAvailable(uid: $0) } ?? false
        input.discard()
        restart(after: lost && activeDevice?.uid == preferredUID ? .deviceLost : .configurationChange)
    }

    private func restart(after reason: AudioCaptureInterruption) {
        stop()
        sinks.notify(reason)
        guard !sinks.isEmpty else { return }
        do {
            try start()
        } catch {
            sinks.notify(.failed(String(describing: error)))
        }
    }
}

/// The subscribers, shared by the actor and the capture thread. Blocks are
/// delivered under the lock, so `remove` waits for a block in flight.
final class SinkRegistry: Sendable {
    private let sinks = OSAllocatedUnfairLock<[(id: UInt64, sink: any AudioSink)]>(initialState: [])

    var isEmpty: Bool { sinks.withLock { $0.isEmpty } }
    var count: Int { sinks.withLock { $0.count } }

    func add(_ sink: any AudioSink, id: UInt64) {
        sinks.withLock { $0.append((id, sink)) }
    }

    func remove(id: UInt64) {
        sinks.withLock { $0.removeAll { $0.id == id } }
    }

    func deliver(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        sinks.withLockUnchecked { sinks in
            for entry in sinks {
                entry.sink.receive(samples, hostTime: hostTime)
            }
        }
    }

    func notify(_ reason: AudioCaptureInterruption) {
        sinks.withLock { sinks in
            for entry in sinks {
                entry.sink.captureInterrupted(reason)
            }
        }
    }
}

/// The audio device behind `AudioCapture`; tests put a fake in its place.
/// Called only on the actor's queue.
protocol AudioInput: AnyObject, Sendable {
    var isAuthorized: Bool { get }
    func isAvailable(uid: String) -> Bool
    /// Starts capture on the device, nil for the system one, and returns the
    /// device it reads. `deliver` gets 16 kHz mono blocks on the capture thread;
    /// `configurationChanged` comes on any thread.
    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               configurationChanged: @escaping @Sendable () -> Void) throws -> Microphone?
    func stop()
    /// Drops the engine: the next start builds one for the new device or format.
    func discard()
}

/// `AVAudioEngine` on the device's own rate. Asking the input for 16 kHz gives
/// silence, so the tap takes the native format and `Resampler` converts.
final class EngineInput: AudioInput, @unchecked Sendable {
    // Touched only on AudioCapture's queue.
    private var engine: AVAudioEngine?
    /// The device the kept engine was built for. A stopped engine misses
    /// device changes, so it is reused only for the same device.
    private var engineDevice = AudioDeviceID(kAudioObjectUnknown)
    private var observer: (any NSObjectProtocol)?

    var isAuthorized: Bool { MicrophoneAccess.status == .authorized }

    func isAvailable(uid: String) -> Bool {
        MicrophoneList.device(uid: uid) != nil
    }

    func start(deviceUID: String?,
               deliver: @escaping @Sendable (UnsafeBufferPointer<Float>, UInt64) -> Void,
               configurationChanged: @escaping @Sendable () -> Void) throws -> Microphone? {
        let target = if let deviceUID { MicrophoneList.device(uid: deviceUID) } else { MicrophoneList.systemDefault() }
        guard let target else { throw AudioCaptureError.noInputDevice }
        if engineDevice != target.id {
            discard()
        }
        let engine = try self.engine ?? makeEngine(device: deviceUID == nil ? nil : target)
        self.engine = engine
        engineDevice = target.id
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            discard()
            throw AudioCaptureError.noInputDevice
        }
        let resampler = try Resampler(inputRate: format.sampleRate)
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            resampler.process(buffer) { deliver($0, hostTime) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            node.removeTap(onBus: 0)
            discard()
            throw AudioCaptureError.engine(String(describing: error))
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in configurationChanged() }
        return currentDevice(of: node)
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func discard() {
        stop()
        engine = nil
        engineDevice = AudioDeviceID(kAudioObjectUnknown)
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

/// Converts the input to 16 kHz mono Float32. Takes the first channel only:
/// averaging the channels of a mic array or an interface can thin out or
/// cancel the voice. Not thread-safe; the capture thread is its only user.
final class Resampler: @unchecked Sendable {
    let inputRate: Double
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var mono: AVAudioPCMBuffer
    private var output: AVAudioPCMBuffer

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

    /// Converts the first channel of a tap buffer; `body` gets the result.
    func process(_ buffer: AVAudioPCMBuffer, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        guard let channels = buffer.floatChannelData, buffer.format.sampleRate == inputRate else { return }
        process(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)), body)
    }

    /// Converts native-rate mono samples. The converter keeps its filter state
    /// between calls, so a stream split into blocks converts as one.
    func process(_ samples: UnsafeBufferPointer<Float>, _ body: (UnsafeBufferPointer<Float>) -> Void) {
        let frames = AVAudioFrameCount(samples.count)
        guard frames > 0 else { return }
        if mono.frameCapacity < frames {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
            mono = bigger
        }
        let wanted = AVAudioFrameCount((Double(frames) * VoiceCore.sampleRate / inputRate).rounded(.up)) + 64
        if output.frameCapacity < wanted {
            guard let bigger = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: wanted) else { return }
            output = bigger
        }
        mono.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        mono.frameLength = frames
        output.frameLength = 0
        let source = InputOnce(mono)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            source.next(outStatus)
        }
        guard status != .error, output.frameLength > 0 else { return }
        body(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
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
