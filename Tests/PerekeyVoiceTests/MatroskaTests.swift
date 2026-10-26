// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// WebM and Matroska files made in the test from bytes: the Opus and AAC
/// packets come out of Core Audio's encoders, the container is written here,
/// in the shapes the parser has to meet (a browser's unknown sizes, lacing,
/// BlockGroups, a file cut short). No fixture is committed.
struct MatroskaTests {
    /// EBML elements as bytes.
    enum EBML {
        static func id(_ value: UInt32) -> [UInt8] {
            var bytes: [UInt8] = []
            var rest = value
            repeat {
                bytes.insert(UInt8(rest & 0xFF), at: 0)
                rest >>= 8
            } while rest > 0
            return bytes
        }

        static func size(_ count: Int) -> [UInt8] {
            if count < 0x7F { return [UInt8(0x80 | count)] }
            if count < 0x3FFF { return [UInt8(0x40 | count >> 8), UInt8(count & 0xFF)] }
            return [0x10 | UInt8(count >> 24), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)]
        }

        /// What a browser writes for the length of a Segment or a Cluster it has not finished.
        static let unknownSize: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

        static func element(_ id: UInt32, _ payload: [UInt8], unknownSize: Bool = false) -> [UInt8] {
            self.id(id) + (unknownSize ? Self.unknownSize : size(payload.count)) + payload
        }

        static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
            var bytes = (0..<8).map { UInt8(value >> UInt64(56 - 8 * $0) & 0xFF) }
            while bytes.count > 1, bytes[0] == 0 { bytes.removeFirst() }
            return element(id, bytes)
        }

        static func text(_ id: UInt32, _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }

        static func float(_ id: UInt32, _ value: Double) -> [UInt8] {
            element(id, (0..<8).map { UInt8(value.bitPattern >> UInt64(56 - 8 * $0) & 0xFF) })
        }
    }

    struct Track {
        var number = 1
        var type = 2
        var codec = "A_OPUS"
        var codecPrivate: [UInt8] = []
        var rate = 48000.0
        var channels = 1
        /// The Channels field as written, if it is not a number of channels.
        var channelsField: UInt64?

        var bytes: [UInt8] {
            var fields = EBML.uint(0xD7, UInt64(number)) + EBML.uint(0x83, UInt64(type)) + EBML.text(0x86, codec)
            if !codecPrivate.isEmpty { fields += EBML.element(0x63A2, codecPrivate) }
            if type == 2 {
                fields += EBML.element(0xE1, EBML.float(0xB5, rate) + EBML.uint(0x9F, channelsField ?? UInt64(channels)))
            }
            return EBML.element(0xAE, fields)
        }
    }

    static func opusHead(preSkip: Int, channels: Int = 1) -> [UInt8] {
        Array("OpusHead".utf8) + [1, UInt8(channels), UInt8(preSkip & 0xFF), UInt8(preSkip >> 8), 0x80, 0xBB, 0, 0, 0, 0, 0]
    }

    /// A WebM file: the EBML header, a Segment holding the tracks and one
    /// Cluster per `perCluster` frames of track 1, each as a SimpleBlock or,
    /// with `groups`, a BlockGroup. `unknownSizes` writes the Segment and the
    /// Clusters as a browser does. A frame is 20 ms after the one before it,
    /// or at `times` (milliseconds) if they are given.
    static func file(tracks: [Track], frames: [[UInt8]], perCluster: Int = 50, unknownSizes: Bool = false,
                     groups: Bool = false, blockTrack: UInt8 = 1, docType: String = "webm", times: [Int]? = nil) -> [UInt8]
    {
        func time(_ index: Int) -> Int { times?[index] ?? index * 20 }
        let header = EBML.element(0x1A45_DFA3, EBML.uint(0x4286, 1) + EBML.text(0x4282, docType))
        var body = EBML.element(0x1549_A966, EBML.uint(0x2AD7B1, 1_000_000))
        body += EBML.element(0x1654_AE6B, tracks.flatMap(\.bytes))
        var clusters: [UInt8] = []
        for start in stride(from: 0, to: frames.count, by: perCluster) {
            var cluster = EBML.uint(0xE7, UInt64(time(start)))
            for (index, frame) in frames[start..<min(start + perCluster, frames.count)].enumerated() {
                let relative = time(start + index) - time(start)
                let block: [UInt8] = [0x80 | blockTrack, UInt8(relative >> 8 & 0xFF), UInt8(relative & 0xFF), groups ? 0 : 0x80] + frame
                cluster += groups ? EBML.element(0xA0, EBML.element(0xA1, block)) : EBML.element(0xA3, block)
            }
            clusters += EBML.element(0x1F43_B675, cluster, unknownSize: unknownSizes)
        }
        return header + EBML.element(0x1853_8067, body + clusters, unknownSize: unknownSizes)
    }

    /// Core Audio's Opus encoder on a silence and then a 440 Hz tone: 20 ms packets.
    static func opusPackets(seconds: Double = 2, toneFrom: Double = 1) throws -> [[UInt8]] {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return try encode(&description, rate: 48000, framesPerPacket: 960, seconds: seconds, toneFrom: toneFrom)
    }

    /// Core Audio's AAC-LC encoder on the same signal at 48 kHz.
    static func aacPackets(seconds: Double = 2, toneFrom: Double = 1) throws -> [[UInt8]] {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
            mReserved: 0)
        return try encode(&description, rate: 48000, framesPerPacket: 1024, seconds: seconds, toneFrom: toneFrom)
    }

    private static func encode(_ description: inout AudioStreamBasicDescription, rate: Double, framesPerPacket: Int,
                               seconds: Double, toneFrom: Double) throws -> [[UInt8]]
    {
        let pcm = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let target = try #require(AVAudioFormat(streamDescription: &description))
        let encoder = try #require(AVAudioConverter(from: pcm, to: target))
        let total = Int(seconds * rate) / framesPerPacket * framesPerPacket
        let input = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(total)))
        input.frameLength = AVAudioFrameCount(total)
        let start = Int(toneFrom * rate)
        for i in 0..<total {
            input.floatChannelData![0][i] = i >= start ? 0.5 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) : 0
        }
        var packets: [[UInt8]] = []
        var given = false
        let out = AVAudioCompressedBuffer(format: target, packetCapacity: 16, maximumPacketSize: 4096)
        while true {
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .endOfStream
                    return nil
                }
                given = true
                status.pointee = .haveData
                return input
            }
            if status == .error { throw error ?? LongAudioError.unreadable }
            if let descriptions = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let packet = descriptions[i]
                    let bytes = out.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self)
                    packets.append(Array(UnsafeBufferPointer(start: bytes, count: Int(packet.mDataByteSize))))
                }
            }
            if status != .haveData { break }
        }
        return packets
    }

    final class Directory {
        let url = URL.temporaryDirectory.appending(path: "perekey-matroska-\(UUID().uuidString)", directoryHint: .isDirectory)

        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let file = url.appending(path: name)
            try Data(bytes).write(to: file)
            return file
        }

        var scratch: URL { url.appending(path: "scratch", directoryHint: .isDirectory) }

        func decode(_ file: URL) async throws -> DecodedFileAudio {
            try await DecodedFileAudio.decode(file, into: scratch)
        }
    }

    /// The first sample louder than a whisper.
    private func onset(_ samples: [Float]) -> Int? { samples.firstIndex { abs($0) > 0.1 } }

    // MARK: Parser

    @Test func browserFileWithUnknownSizes() throws {
        let packets = [[UInt8]](repeating: [1, 2, 3], count: 120)
        let bytes = Self.file(tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets,
                              unknownSizes: true)
        let file = try MatroskaFile(Data(bytes))
        #expect(file.frames.count == 120)
        #expect(file.track.codec == "A_OPUS" && file.track.channels == 1 && file.track.sampleRate == 48000)
        #expect(file.frames.allSatisfy { Array(file.data[$0]) == [1, 2, 3] })
    }

    @Test func firstAudioTrackOnlyAndBlockGroups() throws {
        // A video track first, the audio track second; the blocks say track 2 and 1.
        let tracks = [Track(number: 1, type: 1, codec: "V_VP9"), Track(number: 2, codec: "A_OPUS")]
        // The one block is addressed to the video: no audio frame in the file.
        let video = Self.file(tracks: tracks, frames: [[7, 7]], groups: true, blockTrack: 1)
        #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(video)) }
        let file = try MatroskaFile(Data(Self.file(tracks: tracks, frames: [[7, 7]], groups: true, blockTrack: 2)))
        #expect(file.track.number == 2 && file.frames.count == 1)
        #expect(file.frames.count == 1 && Array(file.data[file.frames[0]]) == [7, 7])
    }

    @Test func lacing() throws {
        func frames(lacing: UInt8, body: [UInt8]) throws -> [[UInt8]] {
            // One SimpleBlock for track 1 whose flags carry the lacing.
            let block = [0x81, 0, 0, lacing << 1] + body
            let cluster = EBML.element(0x1F43_B675, EBML.element(0xA3, block))
            let header = EBML.element(0x1A45_DFA3, EBML.uint(0x4286, 1))
            let file = try MatroskaFile(Data(header + EBML.element(0x1853_8067, EBML.element(0x1654_AE6B, Track().bytes) + cluster)))
            return file.frames.map { Array(file.data[$0]) }
        }
        // Fixed size: three frames of two bytes.
        #expect(try frames(lacing: 2, body: [2, 1, 2, 3, 4, 5, 6]) == [[1, 2], [3, 4], [5, 6]])
        // Xiph: sizes 1 and 300 (255 + 45), the rest is the last frame.
        let long = [UInt8](repeating: 9, count: 300)
        #expect(try frames(lacing: 1, body: [2, 1, 255, 45, 8] + long + [5, 5]) == [[8], long, [5, 5]])
        // EBML: the first size 2, then a difference of +1 against it (3), the rest is the last frame.
        #expect(try frames(lacing: 3, body: [2, 0x82, 0xC0, 1, 1, 2, 2, 2, 3, 3]) == [[1, 1], [2, 2, 2], [3, 3]])
    }

    @Test func fileCutShort() throws {
        let packets = [[UInt8]](repeating: [1, 2, 3, 4, 5], count: 60)
        let bytes = Self.file(tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets,
                              unknownSizes: true)
        // In the middle of the last block: the frames before it.
        let cut = try MatroskaFile(Data(bytes.dropLast(3)))
        #expect(cut.frames.count == 59)
        // Before the first frame, in the header and empty: nothing to read.
        let cluster = try #require(bytes.indices.first { bytes[$0...].starts(with: [0x1F, 0x43, 0xB6, 0x75]) })
        for length in [0, 3, 20, cluster, cluster + 20] {
            #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(bytes.prefix(length))) }
        }
        #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data("RIFF....WAVE".utf8)) }
    }

    // MARK: Hostile files

    /// A file with one SimpleBlock for track 1 and the given flags and body, repeated `blocks` times in one Cluster.
    private static func hostile(flags: UInt8 = 0, body: [UInt8], tracks: [UInt8] = Track().bytes,
                                blocks: Int = 1) -> [UInt8]
    {
        let header = EBML.element(0x1A45_DFA3, EBML.uint(0x4286, 1))
        let block = EBML.element(0xA3, [0x81, 0, 0, flags] + body)
        let cluster = EBML.element(0x1F43_B675, Array([[UInt8]](repeating: block, count: blocks).joined()))
        return header + EBML.element(0x1853_8067, EBML.element(0x1654_AE6B, tracks) + cluster)
    }

    @Test func tracksCutOffInsideATrackEntryHeader() {
        // Tracks of one byte, the ID of a TrackEntry; its size is read past the end of Tracks.
        let header = EBML.element(0x1A45_DFA3, EBML.uint(0x4286, 1))
        let bytes = header + EBML.id(0x1853_8067) + EBML.unknownSize + EBML.id(0x1654_AE6B) + [0x81, 0xAE, 0x85, 1, 2, 3, 4, 5]
        #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(bytes)) }
    }

    @Test func channelsAboveIntMax() throws {
        let track = Track(channelsField: UInt64.max)
        let file = try MatroskaFile(Data(Self.hostile(body: [1, 2, 3], tracks: track.bytes)))
        #expect(file.track.channels == Int.max && file.frames.count == 1)
    }

    @Test func lacingSizesThatOverflow() {
        func lace(_ first: [UInt8], _ difference: [UInt8]) -> [UInt8] {
            [255] + first + Array([[UInt8]](repeating: difference, count: 254).joined())
        }
        // EBML: 256 frames, the first of about 2^55 bytes, 254 differences of the same size up or down.
        let ebml = lace([0x01, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE], [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        let positive = lace([0x01, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE], [0x01, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        // Xiph: 255 sizes of a thousand 255s each, far more than the body holds.
        let xiph = [255] + [UInt8](repeating: 255, count: 255 * 1000) + [1]
        for (kind, body) in [(UInt8(3), ebml), (3, positive), (1, xiph), (2, [255, 1, 2, 3])] {
            #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(Self.hostile(flags: kind << 1, body: body))) }
        }
    }

    @Test func emptyFramesAreLeftOutAndTheirNumberIsCapped() throws {
        // 256 empty frames laced in one byte: no frame. A block with an empty body is no frame either.
        let empty = Self.hostile(flags: 2 << 1, body: [255])
        #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(empty)) }
        let kept = Self.hostile(flags: 0, body: [])
        #expect(throws: LongAudioError.unreadable) { try MatroskaFile(Data(kept)) }
        // Blocks of 256 one-byte frames: past two million frames the file is refused by name.
        let many = Self.hostile(flags: 2 << 1, body: [255] + [UInt8](repeating: 7, count: 256), blocks: 8_000)
        #expect(throws: LongAudioError.unsupported("Matroska with more than two million audio frames")) {
            try MatroskaFile(Data(many))
        }
        let fewer = try MatroskaFile(Data(Self.hostile(flags: 2 << 1, body: [255] + [UInt8](repeating: 7, count: 256), blocks: 3)))
        #expect(fewer.frames.count == 768 && fewer.starts.count == 768)
    }

    // MARK: Decoding

    @Test func opusInBrowserFileDecodesToSixteenKilohertz() async throws {
        let packets = try Self.opusPackets()
        let directory = try Directory()
        let url = try directory.write("call.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets, unknownSizes: true))
        let audio = try await directory.decode(url)
        // 2 s of packets less the pre-skip, at a third of the rate.
        #expect(abs(audio.sampleCount - (packets.count * 960 - 312) / 3) <= 2)
        let samples = try audio.read(0..<audio.sampleCount)
        // The tone starts at 1 s; the encoder's own delay moves it by a few ms.
        let first = try #require(onset(samples))
        #expect(abs(first - 16_000) < 400, "onset \(first)")
        #expect(samples.map(abs).max()! > 0.3 && samples.map(abs).max()! < 0.7)
        audio.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.scratch.path).isEmpty)
    }

    @Test func holeInTheTimestampsIsFilledWithSilence() async throws {
        let packets = try Self.opusPackets()
        // Two seconds missing after the 50th packet: spliced, dropped by OBS, or silence the encoder did not send.
        let times = packets.indices.map { $0 * 20 + ($0 >= 50 ? 2000 : 0) }
        let directory = try Directory()
        let whole = try await directory.decode(directory.write("whole.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets)))
        let holed = try await directory.decode(directory.write("hole.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets, times: times)))
        #expect(abs(holed.sampleCount - whole.sampleCount - 32_000) <= 2)
        let samples = try holed.read(0..<holed.sampleCount)
        // The tone was at 1 s, which is the 50th packet: it now starts 2 s later.
        let first = try #require(onset(samples))
        #expect(abs(first - 48_000) < 400, "onset \(first)")
        // The hole itself is silence.
        #expect(samples[17_000..<47_000].allSatisfy { abs($0) < 0.01 })
        whole.close()
        holed.close()
    }

    @Test func oneWildTimestampJumpGetsNoSilence() async throws {
        let packets = try Self.opusPackets()
        // A jump of three hours after the 50th packet, as a bad splice would leave.
        let times = packets.indices.map { $0 * 20 + ($0 >= 50 ? 3 * 3600 * 1000 : 0) }
        let directory = try Directory()
        let whole = try await directory.decode(directory.write("whole.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets)))
        let jumped = try await directory.decode(directory.write("jump.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets, times: times)))
        #expect(abs(jumped.sampleCount - whole.sampleCount) <= 2)
        let samples = try jumped.read(0..<jumped.sampleCount)
        // The tone at 1 s comes after the jump and is decoded where it was.
        let first = try #require(onset(samples))
        #expect(abs(first - 16_000) < 400, "onset \(first)")
        whole.close()
        jumped.close()
    }

    @Test func aJumpToTheEndOfTimeGetsNoSilence() async throws {
        let packets = try Self.opusPackets()
        // The last millisecond whose nanoseconds still fit in Int64.
        let times = packets.indices.map { $0 >= 50 ? Int(Int64.max / 1_000_000) - (packets.count - $0) * 20 : $0 * 20 }
        let directory = try Directory()
        let whole = try await directory.decode(directory.write("whole.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets)))
        let jumped = try await directory.decode(directory.write("end.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets, times: times)))
        #expect(abs(jumped.sampleCount - whole.sampleCount) <= 2)
        whole.close()
        jumped.close()
    }

    @Test func packetsOfVeryDifferentSizesInOneBatchDecode() async throws {
        var packets = try Self.opusPackets()
        // A one-byte packet (table of contents only) next to the full ones, as a silence-suppressing encoder sends.
        for index in stride(from: 2, to: 40, by: 3) { packets[index] = [packets[index][0] & 0xFC] }
        let directory = try Directory()
        let audio = try await directory.decode(directory.write("mixed.webm", Self.file(
            tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets)))
        #expect(audio.sampleCount > 30_000)
        let samples = try audio.read(0..<audio.sampleCount)
        #expect(onset(samples) != nil)
        audio.close()
    }

    @Test func opusPreSkipIsCutFromTheStart() async throws {
        let packets = try Self.opusPackets()
        let directory = try Directory()
        var counts: [Int] = []
        for preSkip in [0, 3000] {
            let url = try directory.write("skip-\(preSkip).webm", Self.file(
                tracks: [Track(codecPrivate: Self.opusHead(preSkip: preSkip))], frames: packets))
            let audio = try await directory.decode(url)
            counts.append(audio.sampleCount)
            // Core Audio drops 120 samples itself, so a pre-skip of 0 cuts as much as 120 does.
            #expect(abs(audio.sampleCount - (packets.count * 960 - max(preSkip, 120)) / 3) <= 2)
            audio.close()
        }
        #expect(abs(counts[0] - counts[1] - (3000 - 120) / 3) <= 2)
    }

    @Test func aacInMatroska() async throws {
        let packets = try Self.aacPackets()
        let directory = try Directory()
        // AudioSpecificConfig: AAC-LC, 48 kHz, mono.
        let url = try directory.write("obs.mkv", Self.file(
            tracks: [Track(codec: "A_AAC", codecPrivate: [0x11, 0x88])], frames: packets, docType: "matroska"))
        let audio = try await directory.decode(url)
        #expect(abs(audio.sampleCount - packets.count * 1024 / 3) <= 2)
        let first = try #require(onset(try audio.read(0..<audio.sampleCount)))
        #expect(abs(first - 16_000) < 1500, "onset \(first)")
        audio.close()
    }

    @Test func truncatedBrowserFileGivesWhatIsThere() async throws {
        let packets = try Self.opusPackets()
        let bytes = Self.file(tracks: [Track(codecPrivate: Self.opusHead(preSkip: 312))], frames: packets,
                              unknownSizes: true)
        let directory = try Directory()
        let audio = try await directory.decode(try directory.write("cut.webm", Array(bytes.prefix(bytes.count * 2 / 3))))
        #expect(audio.sampleCount > 8_000 && audio.sampleCount < 31_000)
        audio.close()
        // Cut inside the header: nothing, said as unreadable.
        let hopeless = try directory.write("hopeless.webm", Array(bytes.prefix(40)))
        await #expect(throws: LongAudioError.unreadable) { try await directory.decode(hopeless) }
        let empty = try directory.write("empty.webm", [])
        await #expect(throws: LongAudioError.unreadable) { try await directory.decode(empty) }
    }

    @Test func codecsNotDecodedAreNamed() async throws {
        let directory = try Directory()
        let frames = [[UInt8]](repeating: [1, 2, 3], count: 10)
        func name(_ codec: String, channels: Int = 2, private data: [UInt8] = [1], type: String = "mkv") async throws -> String? {
            let url = try directory.write("a.\(type)", Self.file(
                tracks: [Track(codec: codec, codecPrivate: data, channels: channels)], frames: frames))
            do {
                _ = try await directory.decode(url)
                return nil
            } catch let LongAudioError.unsupported(format) {
                return format
            }
        }
        #expect(try await name("A_VORBIS", type: "webm") == "Vorbis")
        #expect(try await name("A_FLAC") == "FLAC")
        #expect(try await name("A_AC3") == "AC-3")
        #expect(try await name("A_DTS/EXPRESS") == "DTS")
        // Opus with a channel map, AAC with SBR or a channel layout in its config.
        #expect(try await name("A_OPUS", channels: 6, private: Self.opusHead(preSkip: 0, channels: 6))
            == "Opus with 6 channels")
        #expect(try await name("A_AAC", channels: 1, private: [0x2B, 0x88]) == "HE-AAC")
    }

    // MARK: Files AVFoundation cannot read and Perekey does not

    @Test func unreadableFormatsAreNamed() async throws {
        let directory = try Directory()
        let asf: [UInt8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0, 0xAA, 0, 0x62, 0xCE, 0x6C]
        let cases: [(file: String, bytes: [UInt8], name: String)] = [
            ("a.wmv", asf, "WMV"), ("a.wma", asf, "WMA"), ("a.asf", asf, "Windows Media"),
            ("a.flv", Array("FLV".utf8) + [1, 5, 0, 0, 0, 9], "FLV"),
            ("a.avi", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI LIST".utf8), "AVI"),
            ("renamed.dat", Array("FLV".utf8) + [1, 5, 0, 0, 0, 9], "FLV"),
        ]
        for (file, bytes, name) in cases {
            let url = try directory.write(file, bytes)
            await #expect(throws: LongAudioError.unsupported(name), "\(file)") { try await directory.decode(url) }
        }
        // Not a format Perekey knows: the file has no audio or cannot be read.
        let text = try directory.write("notes.mp3", Array("hello".utf8))
        await #expect(throws: LongAudioError.unreadable) { try await directory.decode(text) }
        // Matroska by its name only: not Matroska.
        let fake = try directory.write("fake.mkv", Array("hello".utf8))
        await #expect(throws: LongAudioError.unreadable) { try await directory.decode(fake) }
    }
}
