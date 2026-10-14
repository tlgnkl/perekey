// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// Real AAC segments in ADTS, as the call recorder writes them: silence with
/// a loud burst at a known place, so that where the burst comes out tells
/// whether the priming was skipped.
struct RecordingAudioTests {
    final class Fixture {
        let directory = URL.temporaryDirectory.appending(path: "perekey-audio-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// `seconds` of silence with a 440 Hz burst from `burst` s; 16 kHz mono AAC in ADTS.
        func segment(_ name: String, seconds: Double, burst: Double) throws -> String {
            let url = directory.appending(path: name)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            let count = Int(seconds * 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                       frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let start = Int(burst * 16_000)
            for i in 0..<count {
                buffer.floatChannelData![0][i] = i >= start ? 0.8 * sin(Float(i) * 2 * .pi * 440 / 16_000) : 0
            }
            try file.write(from: buffer)
            if #available(macOS 15.0, *) { file.close() }
            return url.path
        }
    }

    /// The first sample louder than a whisper, from `from`.
    private func onset(_ samples: [Float], from: Int = 0) -> Int? {
        samples.indices.dropFirst(from).first { abs(samples[$0]) > 0.2 }
    }

    @Test func trackSkipsPrimingAndKeepsSegmentsAtTheirStarts() throws {
        let fixture = try Fixture()
        // 1.5 s written to the file, 1 s of it in `frames`; then a gap until 3 s.
        let a = try fixture.segment("mic-0001.aac", seconds: 1.5, burst: 0.5)
        let b = try fixture.segment("mic-0002.aac", seconds: 1, burst: 0.25)
        let audio = try TrackAudio([
            TrackSegment(path: a, startOffset: 0, frames: 16_000),
            TrackSegment(path: b, startOffset: 3, frames: 16_000),
        ])
        #expect(audio.sampleCount == 64_000)
        let samples = try audio.read(0..<64_000)
        // AAC smears an onset by up to a block; the priming would put it 2112 samples late.
        let first = try #require(onset(samples))
        #expect(abs(first - 8_000) < 400)
        // Past `frames` and in the gap: nothing.
        #expect(samples[16_000..<48_000].allSatisfy { $0 == 0 })
        let second = try #require(onset(samples, from: 48_000))
        #expect(abs(second - 52_000) < 400)
        // A read across the gap gives the same samples as the whole.
        #expect(try audio.read(40_000..<56_000) == Array(samples[40_000..<56_000]))
        // Past the end: zeros.
        #expect(try audio.read(63_000..<65_000).suffix(1_000).allSatisfy { $0 == 0 })
    }

    /// A segment a crash left open is read to its end, up to the next one.
    @Test func openSegmentRunsToItsEnd() throws {
        let fixture = try Fixture()
        let a = try fixture.segment("sys-0001.aac", seconds: 2, burst: 1.5)
        let b = try fixture.segment("sys-0002.aac", seconds: 1, burst: 0.5)
        let open = try TrackAudio([TrackSegment(path: a, startOffset: 0.5, frames: nil)])
        // About 2 s: AAC pads the last packet.
        #expect(abs(open.sampleCount - (8_000 + 32_000)) < 2_048)
        let first = try #require(onset(try open.read(0..<open.sampleCount)))
        #expect(abs(first - (8_000 + 24_000)) < 400)
        let cut = try TrackAudio([
            TrackSegment(path: a, startOffset: 0, frames: nil),
            TrackSegment(path: b, startOffset: 1, frames: 16_000),
        ])
        #expect(cut.sampleCount == 32_000)
        let samples = try cut.read(0..<32_000)
        // The open segment's burst at 1.5 s is under the next segment, which wins.
        let second = try #require(onset(samples))
        #expect(abs(second - 24_000) < 400)
    }

    @Test func fileIsDecodedToMono16k() async throws {
        let fixture = try Fixture()
        let url = fixture.directory.appending(path: "talk.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = 44_100 * 2
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            for i in 0..<count {
                buffer.floatChannelData![channel][i] = i >= 44_100 ? 0.8 * sin(Float(i) * 2 * .pi * 440 / 44_100) : 0
            }
        }
        try file.write(from: buffer)
        if #available(macOS 15.0, *) { file.close() }
        let scratch = fixture.directory.appending(path: "scratch", directoryHint: .isDirectory)
        let opener = VoiceAudioOpener(scratch: scratch)
        let audio = try await opener.open(.file(VoiceAudioOpener.reference(to: url)))
        #expect(abs(audio.sampleCount - 32_000) < 32)
        let first = try #require(onset(try audio.read(0..<audio.sampleCount)))
        #expect(abs(first - 16_000) < 64)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).count == 1)
        audio.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func fileFollowsItsBookmark() async throws {
        let fixture = try Fixture()
        let url = fixture.directory.appending(path: "a.txt")
        try Data("x".utf8).write(to: url)
        let reference = VoiceAudioOpener.reference(to: url)
        let moved = fixture.directory.appending(path: "b.txt")
        try FileManager.default.moveItem(at: url, to: moved)
        #expect(try VoiceAudioOpener.resolve(reference).lastPathComponent == "b.txt")
        try FileManager.default.removeItem(at: moved)
        #expect(throws: LongAudioError.missing) { try VoiceAudioOpener.resolve(reference) }
        // Not audio: unreadable.
        try Data("x".utf8).write(to: moved)
        await #expect(throws: LongAudioError.unreadable) {
            try await VoiceAudioOpener(scratch: fixture.directory).open(.file(FileReference(path: moved.path)))
        }
    }

    /// What a crashed or stopped queue decoded goes; what is decoded since stays.
    @Test func scratchIsClearedOfOldFiles() throws {
        let fixture = try Fixture()
        let scratch = fixture.directory.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = scratch.appending(path: "old.f32")
        let new = scratch.appending(path: "new.f32")
        try Data([1]).write(to: old)
        try Data([1]).write(to: new)
        let start = Date()
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-60)], ofItemAtPath: old.path)
        VoiceAudioOpener(scratch: scratch).clearScratch(before: start.addingTimeInterval(-1))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: new.path))
    }

    @Test func vbxPsi() throws {
        let floats: [Float] = [1.5, -2]
        let base64 = floats.withUnsafeBytes { Data($0) }.base64EncodedString()
        let json = Data(#"{ "tensors": { "psi": { "data_base64": "\#(base64)" } } }"#.utf8)
        #expect(try VBxDiarizer.psi(json) == [1.5, -2])
        #expect(throws: VBxDiarizer.ModelError.noPsi) { try VBxDiarizer.psi(Data("{}".utf8)) }
    }
}
