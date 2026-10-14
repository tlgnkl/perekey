// SPDX-License-Identifier: GPL-3.0-or-later

import AVFAudio
import Foundation

/// Writes speech as AAC in ADTS frames (`.aac`): a plain stream that any
/// player opens and that needs no container to be finished when the app quits.
public enum AACWriter {
    public enum Failure: Error { case noFormat, noBuffer }

    /// `samples`: mono Float32 at `sampleRate`.
    public static func write(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                         interleaved: false)
        else { throw Failure.noFormat }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let frames = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)),
              let channel = buffer.floatChannelData?[0]
        else { throw Failure.noBuffer }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = frames
        // The file is closed when `file` goes out of scope; write to a side name first so a
        // half-written file never has the final name.
        let partial = url.deletingPathExtension().appendingPathExtension("part").appendingPathExtension(url.pathExtension)
        do {
            do {
                let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32,
                                           interleaved: false)
                try file.write(from: buffer)
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
