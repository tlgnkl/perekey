// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
import PerekeyVoiceCore

/// The file format of the segments. Calls use `adts`; the others stay for
/// the checks that compared them (`--voice-check segments`).
public enum SegmentFormat: String, Sendable, CaseIterable {
    /// AAC in MPEG-4: the index (`moov`) is written when the file closes.
    case m4a
    /// AAC in CAF: the packets go first, the packet table at the close.
    case caf
    /// AAC as an ADTS stream: each packet carries its own header, so a file
    /// cut anywhere reads up to its last whole packet.
    case adts
    /// 16-bit PCM in CAF, as a reference: no encoder state at all.
    case pcm

    var fileExtension: String {
        switch self {
        case .m4a: "m4a"
        case .adts: "aac"
        case .caf, .pcm: "caf"
        }
    }

    var settings: [String: Any] {
        switch self {
        case .m4a, .caf, .adts:
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: VoiceCore.sampleRate,
             AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        case .pcm:
            [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VoiceCore.sampleRate,
             AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        }
    }

    /// `mic-0001.aac`, or the same name with this format's extension.
    func fileName(track: RecordingTrack, number: Int) -> String {
        let name = RecordingMeta.Segment.fileName(track: track, number: number)
        return self == .adts ? name : String(name.dropLast("aac".count)) + fileExtension
    }
}

/// Where a recording's segments are logged: its `meta.json`, and the place
/// of a host time on its scale.
public protocol RecordingLog: Sendable {
    var directory: URL { get }
    /// Seconds on the recording's scale for a host time.
    func offset(of hostTime: UInt64) -> Double
    /// Changes `meta.json` and writes it atomically.
    func update(_ change: (inout RecordingMeta) -> Void) throws
}

/// A recording in a folder of the checks' choosing, outside `Recordings/`:
/// the same `meta.json` as a call's, with no pauses on its scale.
public final class RecordingStore: RecordingLog {
    public let directory: URL
    private let meta: OSAllocatedUnfairLock<RecordingMeta>

    public init(directory: URL, startHostTime: UInt64, format: SegmentFormat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        var meta = RecordingMeta.call(source: .system, startHostTime: startHostTime, audioRetention: .always)
        meta.format = format.rawValue
        self.meta = OSAllocatedUnfairLock(initialState: meta)
        try save()
    }

    public var snapshot: RecordingMeta { meta.withLock { $0 } }

    public func offset(of hostTime: UInt64) -> Double {
        HostTime.seconds(from: meta.withLock { $0.startHostTime ?? 0 }, to: hostTime)
    }

    public func update(_ change: (inout RecordingMeta) -> Void) throws {
        meta.withLockUnchecked { change(&$0) }
        try save()
    }

    public func setState(_ state: RecordingMeta.State) {
        try? update { $0.state = state }
    }

    /// Reads a `meta.json` these stores or the recorder wrote.
    public static func read(_ directory: URL) throws -> RecordingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
    }

    private func save() throws {
        let data = try meta.withLock { meta in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(meta)
        }
        try data.write(to: directory.appending(path: "meta.json"), options: .atomic)
    }
}

/// The level of a track for the recording panel: the peak of the recent
/// blocks, read from any thread.
public final class TrackMeter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (peak: Float(0), at: UInt64(0)))

    public init() {}

    func record(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        var loudest: Float = 0
        for sample in samples {
            loudest = max(loudest, abs(sample))
        }
        let peak = loudest
        state.withLock { state in
            // Holds a peak for a tenth of a second, so the panel sees it.
            if peak >= state.peak || HostTime.seconds(from: state.at, to: hostTime) > 0.1 {
                state = (peak, hostTime)
            }
        }
    }

    func reset() {
        state.withLock { $0 = (0, 0) }
    }

    /// 0…1, a quarter of a second at most old; 0 when nothing came.
    public var level: Float {
        let (peak, at) = state.withLock { $0 }
        guard at > 0, HostTime.seconds(from: at, to: mach_absolute_time()) < 0.25 else { return 0 }
        return min(1, peak)
    }
}

/// One track to disk in segments of `segmentSeconds`: `mic-0001.aac`, …
/// Encodes on the thread that delivers the audio; 16 kHz mono AAC is cheap.
/// Each segment enters `meta.json` when it opens and again, with its frame
/// count, when it closes: a crash leaves the open one marked, and its file
/// reads up to the last whole packet.
///
/// A gap (a device change, a failed write, a pause) closes the segment; the
/// next block opens a new one at its own place on the scale.
public final class SegmentWriter: AudioSink, @unchecked Sendable {
    public let track: RecordingTrack
    public let meter = TrackMeter()
    private let log: any RecordingLog
    private let format: SegmentFormat
    private let segmentFrames: Int64
    /// After a failed write, the track tries a new file this much later.
    private let retryTicks: UInt64
    private let onInterrupted: @Sendable (AudioCaptureInterruption) -> Void
    private let lock = OSAllocatedUnfairLock(initialState: ())
    // Under `lock`.
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer
    private var index = 0
    private var frames: Int64 = 0
    private var failure: String?
    /// Blocks before this host time are dropped: a pause, a failed write.
    private var acceptsFrom: UInt64 = 0
    private var paused = false
    private var finished = false
    private let pcmFormat: AVAudioFormat

    public init(track: RecordingTrack, log: any RecordingLog, format: SegmentFormat = .adts,
                segmentSeconds: Double = CallRecordingLimits.segmentSeconds, retrySeconds: Double = 5,
                onInterrupted: @escaping @Sendable (AudioCaptureInterruption) -> Void = { _ in })
    {
        self.track = track
        self.log = log
        self.format = format
        self.onInterrupted = onInterrupted
        segmentFrames = Int64(segmentSeconds * VoiceCore.sampleRate)
        retryTicks = HostTime.ticks(retrySeconds)
        pcmFormat = AVAudioFormat(standardFormatWithSampleRate: VoiceCore.sampleRate, channels: 1)!
        buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096)!
    }

    /// The last error of a file, if any.
    public var error: String? { lock.withLockUnchecked { failure } }
    public var segmentCount: Int { lock.withLockUnchecked { index } }

    public func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        lock.withLockUnchecked {
            guard !finished, !paused, hostTime >= acceptsFrom, samples.count > 0 else { return }
            meter.record(samples, hostTime: hostTime)
            if file == nil {
                open(hostTime: hostTime)
            }
            guard let file else { return }
            if buffer.frameCapacity < samples.count {
                buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count))!
            }
            buffer.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
            buffer.frameLength = AVAudioFrameCount(samples.count)
            do {
                try file.write(from: buffer)
            } catch {
                failed("\(file.url.lastPathComponent): \(error)", at: hostTime)
                return
            }
            frames += Int64(samples.count)
            if frames >= segmentFrames {
                close()
            }
        }
    }

    /// A gap in the device's audio: the segment closes, and the next block
    /// opens a new one at its own offset.
    public func captureInterrupted(_ reason: AudioCaptureInterruption) {
        lock.withLockUnchecked {
            guard !finished, !paused else { return }
            close()
            meter.reset()
            gap(Self.reason(reason), at: mach_absolute_time())
        }
        onInterrupted(reason)
    }

    static func reason(_ interruption: AudioCaptureInterruption) -> RecordingMeta.Gap.Reason {
        switch interruption {
        case .configurationChange, .deviceLost, .stalled, .deviceChanged, .failed: .deviceChanged
        }
    }

    /// A gap the recorder knows of: the tap was not permitted, say.
    public func interrupt(_ reason: RecordingMeta.Gap.Reason, at hostTime: UInt64) {
        lock.withLockUnchecked {
            guard !finished else { return }
            close()
            gap(reason, at: hostTime)
        }
    }

    /// The pause: the segment closes and blocks are dropped until `resume`.
    /// The recorder writes the pause's gap for both tracks.
    public func pause() {
        lock.withLockUnchecked {
            close()
            paused = true
            meter.reset()
        }
    }

    /// Takes blocks again from this host time on.
    public func resume(from hostTime: UInt64) {
        lock.withLockUnchecked {
            paused = false
            acceptsFrom = max(acceptsFrom, hostTime)
        }
    }

    /// Closes the open segment; nothing more is written.
    public func finish() {
        lock.withLockUnchecked {
            close()
            finished = true
            meter.reset()
        }
    }

    // Under `lock`.

    private func open(hostTime: UInt64) {
        index += 1
        frames = 0
        let name = format.fileName(track: track, number: index)
        let url = log.directory.appending(path: name, directoryHint: .notDirectory)
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            failed("\(name): \(error)", at: hostTime)
            return
        }
        let segment = RecordingMeta.Segment(track: track, file: name, startHostTime: hostTime,
                                            startOffset: log.offset(of: hostTime))
        do {
            try log.update { $0.segments.append(segment) }
        } catch {
            // A segment missing from meta.json would never be read: drop it.
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            try? FileManager.default.removeItem(at: url)
            failed("meta.json: \(error)", at: hostTime)
        }
    }

    private func close() {
        guard let file else { return }
        if #available(macOS 15.0, *) {
            file.close()
        }
        self.file = nil
        let name = file.url.lastPathComponent
        let frames = frames
        try? log.update { meta in
            guard let i = meta.segments.lastIndex(where: { $0.file == name }) else { return }
            meta.segments[i].frames = frames
            meta.segments[i].closed = true
        }
    }

    /// The disk failed: the segment ends, the gap is logged, and the track
    /// tries a new file a few seconds later.
    private func failed(_ message: String, at hostTime: UInt64) {
        failure = message
        close()
        gap(.writeFailed, at: hostTime)
        acceptsFrom = hostTime &+ retryTicks
    }

    private func gap(_ reason: RecordingMeta.Gap.Reason, at hostTime: UInt64) {
        let gap = RecordingMeta.Gap(track: track, startOffset: log.offset(of: hostTime), reason: reason)
        try? log.update { $0.gaps.append(gap) }
    }
}
