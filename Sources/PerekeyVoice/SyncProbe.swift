// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import os
import PerekeyVoiceCore

/// Finds the onsets of clicks in a 16 kHz track. Each onset gets two times:
/// by the block's `mHostTime` plus the sample's place in the block, and by the
/// count of samples since the first block. The first follows the host clock,
/// the second the device's clock, so their difference is the device's drift.
final class ClickDetector: AudioSink, @unchecked Sendable {
    struct Onset: Equatable {
        /// Host seconds by the block's host time.
        var host: Double
        /// Host seconds by the sample count since the first block.
        var counted: Double
        var level: Float
    }

    private let rate: Double
    private let minLevel: Float
    private let ratio: Float
    private let refractory: Double
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var onsets: [Onset] = []
        var floor: Float = 0
        var lastOnset = -Double.infinity
        var firstHost: Double?
        var samples: Int64 = 0
        var peakSinceOnset: Float = 0
    }

    /// An onset is a sample above both `minLevel` and `ratio` times the noise
    /// floor, at least `refractory` seconds after the last one.
    init(rate: Double = VoiceCore.sampleRate, minLevel: Float = 0.002, ratio: Float = 10, refractory: Double = 0.5) {
        self.rate = rate
        self.minLevel = minLevel
        self.ratio = ratio
        self.refractory = refractory
    }

    var onsets: [Onset] { state.withLock { $0.onsets } }

    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        let blockHost = HostClock.seconds(hostTime)
        let rate = rate, minLevel = minLevel, ratio = ratio, refractory = refractory
        let alpha: Float = 1 / Float(rate * 0.2)
        state.withLockUnchecked { state in
            let first = state.firstHost ?? blockHost
            state.firstHost = first
            for (i, sample) in samples.enumerated() {
                let level = abs(sample)
                let host = blockHost + Double(i) / rate
                if host - state.lastOnset < refractory {
                    if !state.onsets.isEmpty {
                        state.onsets[state.onsets.count - 1].level = max(state.onsets[state.onsets.count - 1].level, level)
                    }
                    continue
                }
                if level > max(minLevel, ratio * state.floor) {
                    let counted = first + Double(state.samples + Int64(i)) / rate
                    state.onsets.append(Onset(host: host, counted: counted, level: level))
                    state.lastOnset = host
                } else {
                    state.floor += alpha * (level - state.floor)
                }
            }
            state.samples += Int64(samples.count)
        }
    }
}

/// The time between two tracks over a recording, from clicks both of them hear.
struct SyncAnalysis: Equatable {
    struct Pair: Equatable {
        /// The click in the reference track (the system audio), host seconds.
        var reference: Double
        /// The other track's time minus the reference's, seconds.
        var offset: Double
    }

    var pairs: [Pair]
    var unpaired: Int
    /// Median offset of the first and of the last `edge` pairs.
    var startOffset: Double
    var endOffset: Double
    /// Least-squares slope of the offset, seconds per hour.
    var slopePerHour: Double
    /// The largest distance of a pair from the fitted line.
    var maxResidual: Double
    var span: Double

    var drift: Double { endOffset - startOffset }

    /// Pairs each reference click with the nearest click of `other` within
    /// `window` seconds of the reference plus the typical offset.
    static func analyze(reference: [Double], other: [Double], window: Double = 0.25, edge: Int = 30) -> SyncAnalysis? {
        let others = other.sorted()
        func nearest(_ t: Double) -> Double? {
            var low = 0, high = others.count
            while low < high {
                let mid = (low + high) / 2
                if others[mid] < t { low = mid + 1 } else { high = mid }
            }
            return [low - 1, low].filter { others.indices.contains($0) }.map { others[$0] }
                .min { abs($0 - t) < abs($1 - t) }
        }
        // The typical offset first, so a long acoustic path does not break pairing.
        let rough = median(reference.compactMap { t in nearest(t).map { $0 - t } }.filter { abs($0) < 0.5 })
        guard let rough else { return nil }
        var pairs: [Pair] = []
        for t in reference {
            if let match = nearest(t + rough), abs(match - t - rough) <= window {
                pairs.append(Pair(reference: t, offset: match - t))
            }
        }
        guard pairs.count >= 2 else { return nil }
        let edge = max(1, min(edge, pairs.count / 2))
        let start = median(pairs.prefix(edge).map(\.offset))!
        let end = median(pairs.suffix(edge).map(\.offset))!
        let x = pairs.map { $0.reference - pairs[0].reference }
        let y = pairs.map(\.offset)
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let sxx = zip(x, x).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        let sxy = zip(x, y).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let slope = sxx > 0 ? sxy / sxx : 0
        let residual = zip(x, y).map { abs($1 - (my + slope * ($0 - mx))) }.max() ?? 0
        return SyncAnalysis(pairs: pairs, unpaired: reference.count - pairs.count, startOffset: start, endOffset: end,
                            slopePerHour: slope * 3600, maxResidual: residual, span: x.last ?? 0)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}

/// A short track kept in memory with the host time of its first sample, for
/// measuring how much of one track the other holds.
final class TrackBuffer: AudioSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (start: UInt64(0), samples: [Float]()))

    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        state.withLockUnchecked { state in
            if state.samples.isEmpty {
                state.start = hostTime
            }
            state.samples.append(contentsOf: samples)
        }
    }

    var contents: (start: UInt64, samples: [Float]) { state.withLock { $0 } }
}

/// How much of the system track the microphone heard: the echo a call on
/// speakers leaves in the "Me" track.
struct EchoMeasure: Equatable {
    /// RMS of the system track, dBFS.
    var systemDB: Double
    /// RMS of the microphone while the system played, and in its quiet parts.
    var micDB: Double
    var micQuietDB: Double
    /// Peak normalized correlation of the 1 kHz envelopes, 0…1, and its lag.
    var envelopeCorrelation: Double
    var lag: Double

    /// Both tracks on the host clock; lags from 0 to `maxLag` seconds (the
    /// microphone hears the speakers later).
    static func measure(system: (start: UInt64, samples: [Float]), mic: (start: UInt64, samples: [Float]),
                        rate: Double = VoiceCore.sampleRate, maxLag: Double = 0.3) -> EchoMeasure? {
        let shift = Int((HostClock.seconds(from: system.start, to: mic.start) * rate).rounded())
        // Index i of the system track sits at mic index i - shift.
        let step = Int(rate / 1000)
        func envelope(_ x: ArraySlice<Float>) -> [Double] {
            stride(from: x.startIndex, to: x.endIndex - step + 1, by: step).map { i in
                Double(x[i..<(i + step)].reduce(0) { $0 + abs($1) }) / Double(step)
            }
        }
        let sysStart = max(0, shift), micStart = max(0, -shift)
        let count = min(system.samples.count - sysStart, mic.samples.count - micStart)
        guard count > Int(rate) else { return nil }
        let sys = envelope(system.samples[sysStart..<(sysStart + count)])
        let micEnvelope = envelope(mic.samples[micStart..<(micStart + count)])
        let lags = Int(maxLag * 1000)
        var best = (correlation: -1.0, lag: 0)
        for lag in 0...lags where lag < sys.count / 2 {
            let a = sys[0..<(sys.count - lag)], b = micEnvelope[lag..<micEnvelope.count]
            let c = correlation(Array(a), Array(b))
            if c > best.correlation {
                best = (c, lag)
            }
        }
        // Loud and quiet parts by the system track's envelope.
        let loud = sys.max().map { $0 * 0.1 } ?? 0
        var micLoud: [Double] = [], micQuiet: [Double] = []
        for (i, level) in sys.enumerated() where i + best.lag < micEnvelope.count {
            (level > loud ? { micLoud.append($0) } : { micQuiet.append($0) })(micEnvelope[i + best.lag])
        }
        func db(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return -.infinity }
            return 20 * log10(max(values.reduce(0, +) / Double(values.count), 1e-10))
        }
        return EchoMeasure(systemDB: db(sys), micDB: db(micLoud), micQuietDB: db(micQuiet),
                           envelopeCorrelation: max(0, best.correlation), lag: Double(best.lag) / 1000)
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(min(a.count, b.count))
        guard n > 1 else { return 0 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for (x, y) in zip(a, b) {
            sab += (x - ma) * (y - mb)
            saa += (x - ma) * (x - ma)
            sbb += (y - mb) * (y - mb)
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
    }
}

/// A file of clicks, one every `interval` seconds: a 3 kHz burst with a sharp
/// attack, which a microphone across the room still finds to a millisecond.
/// ALAC at 48 kHz mono: an hour of mostly silence is a few megabytes.
enum ClickTrack {
    static func write(to url: URL, minutes: Double, interval: Double = 1, level: Float = 0.5) throws {
        let rate = 48_000.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let period = Int(interval * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(period))!
        buffer.frameLength = AVAudioFrameCount(period)
        let samples = buffer.floatChannelData![0]
        samples.initialize(repeating: 0, count: period)
        let burst = Int(0.012 * rate)
        for i in 0..<burst {
            let t = Double(i) / rate
            let attack = min(1, Double(i) / 24) // 0.5 ms
            samples[i] = Float(sin(2 * .pi * 3000 * t) * attack * exp(-t / 0.004)) * level
        }
        // A second of silence first: the clicks start once the tap runs.
        let lead = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        lead.frameLength = AVAudioFrameCount(rate)
        lead.floatChannelData![0].initialize(repeating: 0, count: Int(rate))
        try file.write(from: lead)
        for _ in 0..<Int(minutes * 60 / interval) {
            try file.write(from: buffer)
        }
        if #available(macOS 15.0, *) {
            file.close()
        }
    }
}
