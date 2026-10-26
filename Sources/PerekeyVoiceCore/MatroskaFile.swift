// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The first audio track of a Matroska or WebM file (.mkv, .mka, .webm) and
/// where its frames lie. AVFoundation has no demuxer for these. Browsers
/// record calls into WebM as Opus; OBS records MKV.
///
/// The parser is flat: it steps into Segment, Cluster and BlockGroup and
/// skips everything else by its size, so a browser's Segment or Cluster of
/// unknown size (it writes before it knows the length) needs no special
/// case. A file cut off in the middle gives the frames before the cut.
public struct MatroskaFile: Sendable {
    /// The audio track as its header declares it.
    public struct Track: Sendable, Equatable {
        public var number: UInt64 = 0
        /// `A_OPUS`, `A_AAC`, `A_VORBIS`, ...
        public var codec = ""
        public var codecPrivate = Data()
        public var sampleRate: Double = 8000
        public var channels = 1
        /// The encoder's delay and the pre-roll the decoder needs, in nanoseconds.
        public var codecDelay: UInt64 = 0
        public var seekPreRoll: UInt64 = 0
        /// Compression or encryption of the frames: not read.
        public var isEncoded = false
    }

    public let track: Track
    /// The file, mapped: `frames` are ranges in it.
    public let data: Data
    public let frames: [Range<Int>]
    /// Where each frame starts in the recording, in nanoseconds. A block says
    /// when it starts; the frames laced after its first, and the frames of a
    /// block that says nothing usable, are nil.
    public let starts: [Int64?]

    /// More frames than this (11 hours at 20 ms) are not read: a few bytes of
    /// lacing can promise hundreds.
    static let maxFrames = 2_000_000

    /// Whether the file starts with the EBML magic of Matroska and WebM.
    public static func hasMagic(_ head: Data) -> Bool {
        head.starts(with: [0x1A, 0x45, 0xDF, 0xA3])
    }

    /// Whether the extension is one of Matroska's.
    public static func hasExtension(_ url: URL) -> Bool {
        ["webm", "mkv", "mka"].contains(url.pathExtension.lowercased())
    }

    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let info: UInt32 = 0x1549_A966
        static let timecodeScale: UInt32 = 0x2AD7B1
        static let clusterTimestamp: UInt32 = 0xE7
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackNumber: UInt32 = 0xD7
        static let trackType: UInt32 = 0x83
        static let codecID: UInt32 = 0x86
        static let codecPrivate: UInt32 = 0x63A2
        static let codecDelay: UInt32 = 0x56AA
        static let seekPreRoll: UInt32 = 0x56BB
        static let contentEncodings: UInt32 = 0x6D80
        static let audio: UInt32 = 0xE1
        static let samplingFrequency: UInt32 = 0xB5
        static let channels: UInt32 = 0x9F
        static let cluster: UInt32 = 0x1F43_B675
        static let blockGroup: UInt32 = 0xA0
        static let block: UInt32 = 0xA1
        static let simpleBlock: UInt32 = 0xA3
    }

    /// Reads the track and the frame positions; nothing is decoded.
    /// Throws `unreadable` for a file that is not Matroska or has no audio
    /// track, and for one cut off before its first audio frame, and
    /// `unsupported` for one with more frames than `maxFrames`.
    public init(_ data: Data) throws {
        self.data = data
        let reader = Reader(data: data)
        guard reader.id(at: 0) == ID.ebml else { throw LongAudioError.unreadable }
        var track: Track?
        var frames: [Range<Int>] = []
        // Block times in timecode ticks, turned into nanoseconds once the scale is known.
        var ticks: [Int64?] = []
        var scale: UInt64 = 1_000_000
        var cluster: Int64?
        var position = 0
        scan: while let element = reader.element(at: position) {
            switch element.id {
            case ID.segment, ID.info, ID.blockGroup:
                position = element.payload
            case ID.cluster:
                cluster = nil
                position = element.payload
            case ID.timecodeScale, ID.clusterTimestamp:
                guard let end = element.end, end <= data.count else { break scan }
                let value = reader.uint(element.payload..<end)
                if element.id == ID.timecodeScale {
                    if value > 0 { scale = value }
                } else {
                    cluster = Int64(exactly: value)
                }
                position = end
            case ID.tracks:
                guard let end = element.end else { break scan }
                let upper = min(end, data.count)
                if track == nil, element.payload <= upper {
                    track = Self.firstAudio(in: element.payload..<upper, reader)
                }
                position = end
            case ID.simpleBlock, ID.block:
                guard let end = element.end, end <= data.count else { break scan }
                if let track, let found = Self.frames(in: element.payload..<end, of: track.number, reader),
                   !found.frames.isEmpty
                {
                    guard frames.count + found.frames.count <= Self.maxFrames else {
                        throw LongAudioError.unsupported("Matroska with more than two million audio frames")
                    }
                    frames += found.frames
                    // Only the first frame of a block has a time of its own.
                    let (time, overflow) = (cluster ?? 0).addingReportingOverflow(found.relative)
                    ticks.append(cluster == nil || overflow ? nil : time)
                    ticks += [Int64?](repeating: nil, count: found.frames.count - 1)
                }
                position = end
            default:
                // Only a master element has no size; none of these is one we skip.
                guard let end = element.end else { break scan }
                position = end
            }
        }
        guard let track, !frames.isEmpty else { throw LongAudioError.unreadable }
        self.track = track
        self.frames = frames
        let nanoseconds = Int64(clamping: scale)
        starts = ticks.map { tick in
            guard let tick, tick >= 0 else { return nil }
            let (product, overflow) = tick.multipliedReportingOverflow(by: nanoseconds)
            return overflow ? nil : product
        }
    }

    /// The first track of type audio in a Tracks element.
    private static func firstAudio(in range: Range<Int>, _ reader: Reader) -> Track? {
        var position = range.lowerBound
        while position < range.upperBound, let entry = reader.element(at: position) {
            // A header read past the end of Tracks has no payload inside it.
            guard let end = entry.end, entry.payload <= range.upperBound else { return nil }
            if entry.id == ID.trackEntry, let track = entryTrack(in: entry.payload..<min(end, range.upperBound), reader) {
                return track
            }
            position = end
        }
        return nil
    }

    /// The track of a TrackEntry if it is audio.
    private static func entryTrack(in range: Range<Int>, _ reader: Reader) -> Track? {
        var track = Track()
        var type: UInt64 = 0
        var position = range.lowerBound
        while position < range.upperBound, let field = reader.element(at: position) {
            guard let end = field.end, end <= range.upperBound else { break }
            switch field.id {
            case ID.trackNumber: track.number = reader.uint(field.payload..<end)
            case ID.trackType: type = reader.uint(field.payload..<end)
            case ID.codecID: track.codec = String(decoding: reader.data[field.payload..<end], as: UTF8.self)
            case ID.codecPrivate: track.codecPrivate = Data(reader.data[field.payload..<end])
            case ID.codecDelay: track.codecDelay = reader.uint(field.payload..<end)
            case ID.seekPreRoll: track.seekPreRoll = reader.uint(field.payload..<end)
            case ID.contentEncodings: track.isEncoded = true
            case ID.audio:
                var inner = field.payload
                while inner < end, let value = reader.element(at: inner), let valueEnd = value.end, valueEnd <= end {
                    if value.id == ID.samplingFrequency {
                        track.sampleRate = reader.float(value.payload..<valueEnd) ?? track.sampleRate
                    } else if value.id == ID.channels {
                        track.channels = Int(clamping: reader.uint(value.payload..<valueEnd))
                    }
                    inner = valueEnd
                }
            default: break
            }
            position = end
        }
        return type == 2 ? track : nil
    }

    /// The frames of a Block or SimpleBlock if it belongs to `number`: one,
    /// or several if the block is laced, and the block's time relative to its
    /// cluster in ticks. Frames with nothing in them are left out.
    private static func frames(in range: Range<Int>, of number: UInt64, _ reader: Reader)
        -> (frames: [Range<Int>], relative: Int64)?
    {
        guard let (block, length) = reader.size(at: range.lowerBound), block == number else { return nil }
        // Track number, timecode (2 bytes), flags.
        let flagsAt = range.lowerBound + length + 2
        guard flagsAt < range.upperBound else { return nil }
        let lacing = (reader.data[flagsAt] >> 1) & 3
        let body = (flagsAt + 1)..<range.upperBound
        let relative = Int64(Int16(bitPattern: UInt16(reader.data[flagsAt - 2]) << 8 | UInt16(reader.data[flagsAt - 1])))
        let frames = lacing == 0 ? [body] : reader.laced(body, kind: lacing)
        return frames.map { ($0.filter { !$0.isEmpty }, relative) }
    }

    /// Reads EBML numbers and element headers from the mapped file.
    struct Reader {
        let data: Data

        struct Element {
            let id: UInt32
            let payload: Int
            let size: UInt64?
            /// Past the last byte of the payload; nil if the size is unknown.
            var end: Int? {
                guard let size else { return nil }
                let (sum, overflow) = payload.addingReportingOverflow(Int(clamping: size))
                return overflow ? Int.max : sum
            }
        }

        func byte(_ index: Int) -> UInt8? {
            index >= data.startIndex && index < data.endIndex ? data[index] : nil
        }

        /// An element ID: 1 to 4 bytes, the length marker kept.
        func id(at index: Int) -> UInt32? {
            guard let first = byte(index), first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard length <= 4, index + length <= data.endIndex else { return nil }
            return (0..<length).reduce(0) { $0 << 8 | UInt32(data[index + $1]) }
        }

        /// A size: 1 to 8 bytes, the marker removed. `nil` is "unknown", all ones.
        func size(at index: Int) -> (value: UInt64?, length: Int)? {
            guard let first = byte(index), first != 0 else { return nil }
            let length = first.leadingZeroBitCount + 1
            guard index + length <= data.endIndex else { return nil }
            var value = UInt64(first) & (0xFF >> UInt8(length))
            var ones = value == (0xFF >> UInt8(length))
            for i in 1..<length {
                value = value << 8 | UInt64(data[index + i])
                ones = ones && data[index + i] == 0xFF
            }
            return (ones ? nil : value, length)
        }

        func element(at index: Int) -> Element? {
            guard let id = id(at: index) else { return nil }
            let idLength = id > 0xFFFFFF ? 4 : id > 0xFFFF ? 3 : id > 0xFF ? 2 : 1
            guard let (size, length) = self.size(at: index + idLength) else { return nil }
            return Element(id: id, payload: index + idLength + length, size: size)
        }

        func uint(_ range: Range<Int>) -> UInt64 {
            range.prefix(8).reduce(0) { $0 << 8 | UInt64(data[$1]) }
        }

        func float(_ range: Range<Int>) -> Double? {
            switch range.count {
            case 4: Double(Float(bitPattern: UInt32(uint(range))))
            case 8: Double(bitPattern: uint(range))
            default: nil
            }
        }

        /// The frames of a laced block body: Xiph (1), fixed-size (2) or EBML (3) lacing.
        /// Every size is checked as it is read, against what the body can hold.
        func laced(_ body: Range<Int>, kind: UInt8) -> [Range<Int>]? {
            guard let count = byte(body.lowerBound).map({ Int($0) + 1 }) else { return nil }
            var position = body.lowerBound + 1
            var sizes: [Int] = []
            var total = 0
            func add(_ size: Int) -> Bool {
                guard size >= 0, size <= body.count - total else { return false }
                sizes.append(size)
                total += size
                return true
            }
            switch kind {
            case 2:
                let each = (body.upperBound - position) / count
                guard each * count == body.upperBound - position else { return nil }
                for _ in 0..<count { _ = add(each) }
            case 1:
                for _ in 0..<(count - 1) {
                    var value = 0
                    while true {
                        guard position < body.upperBound, let next = byte(position) else { return nil }
                        position += 1
                        value += Int(next)
                        if next != 255 { break }
                        // Past what the body holds: the size is wrong, and the sum must not grow.
                        guard value <= body.count else { return nil }
                    }
                    guard add(value) else { return nil }
                }
            default:
                if count > 1 {
                    guard let (first, length) = size(at: position), let start = first, position + length <= body.upperBound,
                          add(Int(clamping: start)) else { return nil }
                    position += length
                }
                for _ in 2..<max(2, count) {
                    // A signed difference from the previous size, in the bias of its length.
                    guard let (raw, deltaLength) = size(at: position), let delta = raw, position + deltaLength <= body.upperBound
                    else { return nil }
                    position += deltaLength
                    let bias = (1 << (7 * deltaLength - 1)) - 1
                    let (next, overflow) = sizes[sizes.count - 1].addingReportingOverflow(Int(clamping: delta) - bias)
                    guard !overflow, add(next) else { return nil }
                }
            }
            // The last frame is the rest; fixed-size lacing has it in `sizes` already.
            if kind != 2, !add(body.upperBound - position - total) { return nil }
            guard position + total <= body.upperBound else { return nil }
            var frames: [Range<Int>] = []
            for size in sizes {
                frames.append(position..<(position + size))
                position += size
            }
            return frames
        }
    }
}
