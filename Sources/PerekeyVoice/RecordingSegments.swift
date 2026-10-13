// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
import PerekeyVoiceCore

/// `meta.json` of a call recording: where each track's segments sit on the
/// recording's time scale. Durations of segments are never summed: AAC adds
/// priming frames to every file, so each segment carries its own start.
public struct RecordingMeta: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public enum State: String, Codable, Sendable {
        case recording, stopped, transcribing, done
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var track: String
        public var file: String
        /// `mHostTime` of the segment's first sample.
        public var startHostTime: UInt64
        /// Seconds from the start of the recording to the first sample.
        public var startOffset: Double
        /// Samples written; 0 while the segment is open.
        public var frames: Int64
        public var closed: Bool
    }

    /// Audio missing from a track: a device change or a failure.
    public struct Gap: Codable, Sendable, Equatable {
        public var track: String
        public var startOffset: Double
        public var reason: String
    }

    public var schemaVersion = Self.currentSchema
    public var state = State.recording
    public var startHostTime: UInt64
    public var sampleRate = VoiceCore.sampleRate
    public var format: String
    public var segments: [Segment] = []
    public var gaps: [Gap] = []

    public init(startHostTime: UInt64, format: String) {
        self.startHostTime = startHostTime
        self.format = format
    }
}

/// The file format of the segments.
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
}

/// The recording's directory and its `meta.json`, shared by the tracks. Each
/// change rewrites the file atomically: a temporary file, then `rename`.
public final class RecordingStore: Sendable {
    public let directory: URL
    private let meta: OSAllocatedUnfairLock<RecordingMeta>

    public init(directory: URL, startHostTime: UInt64, format: SegmentFormat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        meta = OSAllocatedUnfairLock(initialState: RecordingMeta(startHostTime: startHostTime, format: format.rawValue))
        try save()
    }

    public var snapshot: RecordingMeta { meta.withLock { $0 } }

    /// Seconds on the recording's scale for a host time.
    public func offset(of hostTime: UInt64) -> Double {
        HostClock.seconds(from: meta.withLock { $0.startHostTime }, to: hostTime)
    }

    func update(_ change: @Sendable (inout RecordingMeta) -> Void) {
        meta.withLock { change(&$0) }
        try? save()
    }

    public func setState(_ state: RecordingMeta.State) {
        update { $0.state = state }
    }

    private func save() throws {
        let data = try meta.withLock { meta in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(meta)
        }
        try data.write(to: directory.appending(path: "meta.json"), options: .atomic)
    }
}

/// One track to disk in segments of `segmentSeconds`: `<track>-0001.m4a`, …
/// Encodes on the thread that delivers the audio; 16 kHz mono AAC is cheap.
/// Each segment enters `meta.json` when it opens and again, with its frame
/// count, when it closes.
public final class SegmentWriter: AudioSink, @unchecked Sendable {
    public let track: String
    private let store: RecordingStore
    private let format: SegmentFormat
    private let segmentFrames: Int64
    private let lock = OSAllocatedUnfairLock(initialState: ())
    // Under `lock`.
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer
    private var index = 0
    private var frames: Int64 = 0
    private var failure: String?
    private let pcmFormat: AVAudioFormat

    public init(track: String, store: RecordingStore, format: SegmentFormat, segmentSeconds: Double) {
        self.track = track
        self.store = store
        self.format = format
        segmentFrames = Int64(segmentSeconds * VoiceCore.sampleRate)
        pcmFormat = AVAudioFormat(standardFormatWithSampleRate: VoiceCore.sampleRate, channels: 1)!
        buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4096)!
    }

    /// The first error of a file, if any: the track stops writing then.
    public var error: String? { lock.withLockUnchecked { failure } }
    public var segmentCount: Int { lock.withLockUnchecked { index } }

    public func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        lock.withLockUnchecked {
            guard failure == nil, samples.count > 0 else { return }
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
                failure = "\(track)-\(index): \(error)"
                return
            }
            frames += Int64(samples.count)
            if frames >= segmentFrames {
                close()
            }
        }
    }

    /// A gap: the segment closes, the next block opens a new one at its own offset.
    public func captureInterrupted(_ reason: AudioCaptureInterruption) {
        lock.withLockUnchecked {
            close()
            let track = track
            let offset = store.offset(of: mach_absolute_time())
            store.update { $0.gaps.append(.init(track: track, startOffset: offset, reason: "\(reason)")) }
        }
    }

    /// Closes the open segment.
    public func finish() {
        lock.withLockUnchecked { close() }
    }

    private func open(hostTime: UInt64) {
        index += 1
        frames = 0
        let name = String(format: "%@-%04d.%@", track, index, format.fileExtension)
        do {
            file = try AVAudioFile(forWriting: store.directory.appending(path: name), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            failure = "\(name): \(error)"
            return
        }
        let segment = RecordingMeta.Segment(track: track, file: name, startHostTime: hostTime,
                                            startOffset: store.offset(of: hostTime), frames: 0, closed: false)
        store.update { $0.segments.append(segment) }
    }

    private func close() {
        guard let file else { return }
        if #available(macOS 15.0, *) {
            file.close()
        }
        self.file = nil
        let name = file.url.lastPathComponent
        let frames = frames
        store.update { meta in
            guard let i = meta.segments.lastIndex(where: { $0.file == name }) else { return }
            meta.segments[i].frames = frames
            meta.segments[i].closed = true
        }
    }
}
