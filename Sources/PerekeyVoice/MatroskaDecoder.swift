// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation
import PerekeyVoiceCore

/// The frames of a Matroska or WebM audio track as 16 kHz mono floats, the
/// way `DecodedFileAudio` keeps them. Core Audio decodes Opus (what browsers
/// record) and AAC (what OBS can record); it has no Vorbis decoder, so the
/// others are refused by name.
struct MatroskaDecoder {
    private let file: MatroskaFile
    private let compressed: AVAudioFormat
    /// What the decoder produces: the rate and channels the codec was made for.
    private let rate: Double
    private let channels: Int
    /// Samples at the start of the decoder's output that are not the recording:
    /// the pre-skip of Opus.
    private let skip: Int
    private let gain: Float
    /// Whether packets differ in length, so each tells its frame count.
    private let variablePackets: Bool

    /// Samples at 48 kHz that Core Audio's Opus decoder leaves out of the start of its output.
    private static let opusDecoderDelay = 120

    init(_ file: MatroskaFile) throws {
        self.file = file
        let track = file.track
        if track.isEncoded { throw LongAudioError.unsupported("Matroska with encrypted or compressed audio") }
        var description = AudioStreamBasicDescription()
        switch track.codec {
        case "A_OPUS":
            // OpusHead: version, channels, pre-skip (48 kHz samples), input rate, gain (Q7.8 dB), mapping family.
            let head = track.codecPrivate
            guard head.count >= 19, head.starts(with: Array("OpusHead".utf8)) else { throw LongAudioError.unreadable }
            let base = head.startIndex
            channels = Int(head[base + 9])
            // Only mono and stereo have mapping family 0; the rest need a channel map.
            guard head[base + 18] == 0, (1...2).contains(channels) else {
                throw LongAudioError.unsupported("Opus with \(channels) channels")
            }
            // Core Audio's decoder already drops the first 120 samples (2.5 ms) of a stream.
            skip = max(0, (Int(head[base + 10]) | Int(head[base + 11]) << 8) - Self.opusDecoderDelay)
            let q78 = Int16(bitPattern: UInt16(head[base + 16]) | UInt16(head[base + 17]) << 8)
            gain = q78 == 0 ? 1 : Float(pow(10, Double(q78) / (20 * 256)))
            rate = 48000
            variablePackets = true
            description = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0,
                mReserved: 0)
        case "A_AAC":
            let config = try Self.audioSpecificConfig(track.codecPrivate)
            // The track's rate is the output's: twice the core's means SBR (HE-AAC), implied.
            guard config.object == 2, abs(track.sampleRate - config.rate) < 1 else {
                throw LongAudioError.unsupported("HE-AAC")
            }
            channels = config.channels
            rate = config.rate
            // The encoder's delay, if the muxer wrote it (ffmpeg does).
            skip = Int((Double(track.codecDelay) * rate / 1e9).rounded())
            gain = 1
            variablePackets = false
            description = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 0, mReserved: 0)
        default:
            throw LongAudioError.unsupported(Self.name(of: track.codec))
        }
        guard let format = AVAudioFormat(streamDescription: &description) else { throw LongAudioError.unreadable }
        compressed = format
    }

    /// The name of a codec for the person: "Vorbis" for `A_VORBIS`.
    static func name(of codec: String) -> String {
        switch codec {
        case "A_VORBIS": "Vorbis"
        case "A_FLAC": "FLAC"
        case "A_AC3", "A_EAC3": "AC-3"
        case "A_MPEG/L3": "MP3 in Matroska"
        case "A_MPEG/L2": "MP2"
        case "": "unknown"
        default:
            codec.hasPrefix("A_DTS") ? "DTS"
                : codec.hasPrefix("A_PCM") ? "PCM in Matroska"
                : codec.hasPrefix("A_") ? String(codec.dropFirst(2)) : codec
        }
    }

    /// The object type, rate and channels at the start of an AudioSpecificConfig.
    static func audioSpecificConfig(_ data: Data) throws -> (object: Int, rate: Double, channels: Int) {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard data.count >= 2 else { throw LongAudioError.unreadable }
        let bytes = Array(data.prefix(2))
        let object = Int(bytes[0] >> 3)
        let index = Int(bytes[0] & 7) << 1 | Int(bytes[1] >> 7)
        let channels = Int(bytes[1] >> 3) & 15
        // An escape in the object type, an explicit rate or a channel layout in the config itself: not read.
        guard object != 31, index < rates.count else { throw LongAudioError.unsupported("AAC") }
        guard (1...2).contains(channels) else { throw LongAudioError.unsupported("AAC with \(channels) channels") }
        return (object, rates[index], channels)
    }

    /// Hands out the samples, decoded and resampled, in pieces.
    func run(_ emit: ([Float]) throws -> Void) throws {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let decoder = AVAudioConverter(from: compressed, to: pcm)
        else { throw LongAudioError.unreadable }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceCore.sampleRate, channels: 1,
                                   interleaved: false)!
        let resampler = rate == VoiceCore.sampleRate ? nil : AVAudioConverter(from: mono, to: target)
        if rate != VoiceCore.sampleRate, resampler == nil { throw LongAudioError.unreadable }
        guard let decoded = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192),
              let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192)
        else { throw LongAudioError.unreadable }

        var toSkip = skip
        // One piece of decoded audio: past the pre-skip, in mono, resampled.
        func consume(_ buffer: AVAudioPCMBuffer) throws {
            let count = Int(buffer.frameLength)
            let drop = min(toSkip, count)
            toSkip -= drop
            guard count > drop, let channelData = buffer.floatChannelData else { return }
            let mixed = single.floatChannelData![0]
            for i in drop..<count {
                var sum: Float = 0
                for channel in 0..<channels { sum += channelData[channel][i] }
                mixed[i - drop] = sum / Float(channels) * gain
            }
            single.frameLength = AVAudioFrameCount(count - drop)
            if let resampler {
                try Self.convert(resampler, source: single, capacity: 4096, emit)
            } else {
                try emit(Array(UnsafeBufferPointer(start: mixed, count: count - drop)))
            }
        }

        var next = 0
        while next < file.frames.count {
            try Task.checkCancellation()
            let batch = file.frames[next..<min(next + 64, file.frames.count)]
            next += batch.count
            let packets = try packetBuffer(batch)
            var supplied = false
            while true {
                decoded.frameLength = 0
                var error: NSError?
                let status = decoder.convert(to: decoded, error: &error) { _, status in
                    if supplied {
                        status.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    status.pointee = .haveData
                    return packets
                }
                if status == .error { throw LongAudioError.unreadable }
                if decoded.frameLength > 0 { try consume(decoded) }
                if status != .haveData { break }
            }
        }
        if let resampler {
            // The end of the stream lets the resampler give out its tail.
            var error: NSError?
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return }
            _ = resampler.convert(to: out, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0, let data = out.floatChannelData {
                try emit(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
            }
        }
    }

    /// Runs `source` through a converter and hands out all it gives.
    private static func convert(_ converter: AVAudioConverter, source: AVAudioPCMBuffer, capacity: AVAudioFrameCount,
                                _ emit: ([Float]) throws -> Void) throws
    {
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        while true {
            out.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return source
            }
            if status == .error { throw LongAudioError.unreadable }
            if out.frameLength > 0, let data = out.floatChannelData {
                try emit(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
            }
            if status != .haveData { break }
        }
    }

    /// The frames of `batch` as one buffer of packets.
    private func packetBuffer(_ batch: ArraySlice<Range<Int>>) throws -> AVAudioCompressedBuffer {
        let longest = batch.map(\.count).max() ?? 0
        let packets = AVAudioCompressedBuffer(format: compressed, packetCapacity: AVAudioPacketCount(batch.count),
                                              maximumPacketSize: max(1, longest))
        guard let descriptions = packets.packetDescriptions else { throw LongAudioError.unreadable }
        var offset = 0
        for (index, range) in batch.enumerated() {
            let frame = file.data[range]
            frame.copyBytes(to: packets.data.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: frame.count)
            descriptions[index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset),
                mVariableFramesInPacket: variablePackets ? UInt32(Self.opusFrames(frame)) : 0,
                mDataByteSize: UInt32(frame.count))
            offset += frame.count
        }
        packets.packetCount = AVAudioPacketCount(batch.count)
        packets.byteLength = UInt32(offset)
        return packets
    }

    /// The samples at 48 kHz in an Opus packet, from its table-of-contents byte.
    static func opusFrames(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        // 2.5, 5, 10, 20, 40 and 60 ms in samples at 48 kHz.
        let size: Int
        switch config {
        case 0...11: size = [480, 960, 1920, 2880][config & 3]
        case 12...15: size = config & 1 == 0 ? 480 : 960
        default: size = [120, 240, 480, 960][config & 3]
        }
        switch toc & 3 {
        case 0: return size
        case 3: return size * Int(packet.count > packet.startIndex + 1 ? packet[packet.startIndex + 1] & 0x3F : 0)
        default: return size * 2
        }
    }
}
