// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os
import PerekeyVoiceCore

/// Opens the audio of a recording for the file queue and the diarizer: a
/// track's segments as they lie, a file decoded to 16 kHz mono first.
public struct VoiceAudioOpener: LongAudioOpener {
    /// Where decoded files go while they are transcribed.
    public let scratch: URL

    public init(scratch: URL = FileManager.default.temporaryDirectory
        .appending(path: "Perekey Transcription", directoryHint: .isDirectory))
    {
        self.scratch = scratch
    }

    public func open(_ source: PerekeyVoiceCore.AudioSource) async throws -> any LongAudio {
        switch source {
        case let .track(_, segments):
            return try TrackAudio(segments)
        case let .file(reference):
            let url = try Self.resolve(reference)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await DecodedFileAudio.decode(url, into: scratch)
        }
    }

    /// Removes decoded files older than `date`: those of a queue that
    /// crashed or was stopped. Files decoded since stay.
    public func clearScratch(before date: Date) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < date { try? manager.removeItem(at: file) }
        }
    }

    /// The file by its bookmark, which follows a move or a rename; by its
    /// path if there is no bookmark or it fails.
    static func resolve(_ reference: FileReference) throws -> URL {
        if let bookmark = reference.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path)
            {
                return url
            }
        }
        let url = URL(filePath: reference.path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LongAudioError.missing }
        return url
    }

    /// The reference to keep in `meta.json` for a file the user chose.
    public static func reference(to url: URL) -> FileReference {
        FileReference(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                                      relativeTo: nil))
    }
}

/// A track of a call on the recording's scale: each AAC segment at its
/// start, without the 2112 frames of priming, cut to the frames written;
/// zeros where the track had a gap. Reads only what is asked.
public final class TrackAudio: LongAudio, AudioSampleSource, @unchecked Sendable {
    private struct Piece {
        let url: URL
        /// First and past-the-last sample on the scale.
        let start: Int
        let end: Int
    }

    private let segments: [TrackSegment]
    private let pieces: [Piece]
    public let sampleCount: Int
    private let lock = OSAllocatedUnfairLock()
    // Under `lock`: the segment file read last.
    private var open: (url: URL, file: AVAudioFile)?

    public init(_ segments: [TrackSegment]) throws {
        let rate = VoiceCore.sampleRate
        self.segments = segments
        var pieces: [Piece] = []
        for (index, segment) in segments.enumerated() {
            let url = URL(filePath: segment.path)
            let start = Int((segment.startOffset * rate).rounded(.up))
            var frames: Int
            if let written = segment.frames {
                frames = Int(written)
            } else {
                // Open after a crash: what decodes, up to the next segment.
                guard let file = try? AVAudioFile(forReading: url) else { continue }
                frames = max(0, Int(file.length - RecordingMeta.adtsPrimingFrames))
            }
            if index + 1 < segments.count {
                frames = min(frames, Int((segments[index + 1].startOffset * rate).rounded(.up)) - start)
            }
            if frames > 0 { pieces.append(Piece(url: url, start: start, end: start + frames)) }
        }
        guard let last = pieces.last else { throw LongAudioError.unreadable }
        self.pieces = pieces
        sampleCount = last.end
    }

    public func read(_ range: Range<Int>) throws -> [Float] {
        var out = [Float](repeating: 0, count: range.count)
        try out.withUnsafeMutableBufferPointer { buffer in
            try copySamples(into: buffer.baseAddress!, offset: range.lowerBound, count: range.count)
        }
        return out
    }

    /// FluidAudio's diarizer reads the track from disk through this.
    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        destination.initialize(repeating: 0, count: count)
        let end = offset + count
        let rate = VoiceCore.sampleRate
        for piece in pieces where piece.start < end && piece.end > offset {
            let from = max(offset, piece.start)
            let to = min(end, piece.end)
            // The frame in the file by the same rule the window plays a phrase by.
            let found = segments.locate(Double(from) / rate)
            let frame = found.flatMap { segments[$0.segment].path == piece.url.path ? $0.frame : nil }
                ?? RecordingMeta.adtsPrimingFrames + Int64(from - piece.start)
            try lock.withLockUnchecked {
                try decode(piece.url, frame: frame, count: to - from, into: destination + (from - offset))
            }
        }
    }

    private func decode(_ url: URL, frame: Int64, count: Int, into destination: UnsafeMutablePointer<Float>) throws {
        if open?.url != url {
            open = (url, try AVAudioFile(forReading: url))
        }
        let file = open!.file
        guard frame < file.length else { return }
        file.framePosition = frame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { return }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let channel = buffer.floatChannelData?[0] else { return }
        destination.update(from: channel, count: min(count, Int(buffer.frameLength)))
    }
}

/// A file the user chose, decoded once to 16 kHz mono floats in a scratch
/// file and read from it mapped: the windows and the diarizer jump around
/// in it, which compressed audio does badly. An hour takes 230 MB on disk,
/// none of it in memory; the scratch file goes when the job does.
public final class DecodedFileAudio: LongAudio, AudioSampleSource, @unchecked Sendable {
    public let url: URL
    public let sampleCount: Int
    private let data: Data

    init(url: URL) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .alwaysMapped)
        sampleCount = data.count / MemoryLayout<Float>.size
    }

    /// Decodes everything AVFoundation reads (mp3, m4a, wav, mp4, mov): all
    /// audio tracks mixed, resampled to 16 kHz mono by the reader itself.
    /// What it cannot read goes to the Matroska reader (webm, mkv, mka), or
    /// is named, if Perekey knows the format and cannot decode it.
    static func decode(_ source: URL, into scratch: URL) async throws -> DecodedFileAudio {
        do {
            return try await decodeWithAVFoundation(source, into: scratch)
        } catch LongAudioError.unreadable {
            let head = (try? FileHandle(forReadingFrom: source)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 16)
            } ?? Data()
            if MatroskaFile.hasMagic(head) || MatroskaFile.hasExtension(source) {
                return try decodeMatroska(source, into: scratch)
            }
            if let format = UnreadableFormat.name(of: source, head: head) { throw LongAudioError.unsupported(format) }
            throw LongAudioError.unreadable
        }
    }

    /// WebM and Matroska: the first audio track, Opus or AAC.
    private static func decodeMatroska(_ source: URL, into scratch: URL) throws -> DecodedFileAudio {
        // A file that is not Matroska after all is not audio.
        let file = try MatroskaFile(Data(contentsOf: source, options: .alwaysMapped))
        let decoder = try MatroskaDecoder(file)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appending(path: UUID().uuidString + ".f32", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try decoder.run { samples in
                try samples.withUnsafeBytes { try handle.write(contentsOf: $0) }
            }
            try handle.close()
            let audio = try DecodedFileAudio(url: target)
            guard audio.sampleCount > 0 else { throw LongAudioError.unreadable }
            return audio
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    private static func decodeWithAVFoundation(_ source: URL, into scratch: URL) async throws -> DecodedFileAudio {
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw LongAudioError.unreadable
        }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LongAudioError.unreadable
        }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: VoiceCore.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw LongAudioError.unreadable }
        reader.add(output)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appending(path: UUID().uuidString + ".f32", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            guard reader.startReading() else { throw LongAudioError.unreadable }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                                  dataPointerOut: &pointer) == noErr
                else { continue }
                if let pointer, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
                    try handle.write(contentsOf: Data(bytesNoCopy: pointer, count: length, deallocator: .none))
                } else {
                    var bytes = Data(count: length)
                    _ = bytes.withUnsafeMutableBytes { buffer in
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                   destination: buffer.baseAddress!)
                    }
                    try handle.write(contentsOf: bytes)
                }
            }
            if reader.status == .failed { throw LongAudioError.unreadable }
            try handle.close()
            let audio = try DecodedFileAudio(url: target)
            guard audio.sampleCount > 0 else { throw LongAudioError.unreadable }
            return audio
        } catch {
            reader.cancelReading()
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    public func read(_ range: Range<Int>) throws -> [Float] {
        var out = [Float](repeating: 0, count: range.count)
        try out.withUnsafeMutableBufferPointer { buffer in
            try copySamples(into: buffer.baseAddress!, offset: range.lowerBound, count: range.count)
        }
        return out
    }

    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        destination.initialize(repeating: 0, count: count)
        let from = max(0, offset)
        let to = min(sampleCount, offset + count)
        guard from < to else { return }
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            (destination + (from - offset)).update(from: floats.baseAddress! + from, count: to - from)
        }
    }

    public func close() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Formats the file filters let in that AVFoundation cannot read and Perekey
/// does not decode: named, so the error can say what to convert from.
enum UnreadableFormat {
    static func name(of url: URL, head: Data) -> String? {
        let ext = url.pathExtension.lowercased()
        // ASF holds WMA and WMV; the extension tells them apart.
        if head.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return ["wma", "wmv"].contains(ext) ? ext.uppercased() : "Windows Media"
        }
        if head.starts(with: Array("FLV".utf8)) { return "FLV" }
        if head.starts(with: Array("RIFF".utf8)), head.dropFirst(8).starts(with: Array("AVI ".utf8)) { return "AVI" }
        return ["wma", "wmv", "flv", "avi"].contains(ext) ? ext.uppercased() : nil
    }
}
