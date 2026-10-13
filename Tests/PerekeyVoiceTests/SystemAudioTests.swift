// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreAudio
import Foundation
@testable import PerekeyVoice
import Testing

@Suite struct AudioProcessMatchingTests {
    private let processes = [
        AudioProcess(id: 1, pid: 100, bundleID: "com.google.Chrome", responsiblePID: 100, isRunningOutput: false),
        AudioProcess(id: 2, pid: 101, bundleID: "com.google.Chrome.helper", responsiblePID: 100, isRunningOutput: true),
        AudioProcess(id: 3, pid: 200, bundleID: "com.apple.WebKit.GPU", responsiblePID: 300, isRunningOutput: true),
        AudioProcess(id: 4, pid: 400, bundleID: "com.apple.Music", responsiblePID: 400, isRunningOutput: true),
        AudioProcess(id: 5, pid: 500, bundleID: "com.google.ChromeRemoteDesktop", responsiblePID: 500, isRunningOutput: false),
        AudioProcess(id: 6, pid: 600, bundleID: nil, responsiblePID: 600, isRunningOutput: true),
    ]

    @Test func appTakesHelpersByBundleIDPrefix() {
        let members = AudioProcessList.members(of: .app(bundleID: "com.google.Chrome"), in: processes,
                                               appPIDs: [100], ownPID: 1)
        #expect(members.map(\.id) == [1, 2])
    }

    @Test func appTakesHelpersItIsResponsibleFor() {
        // Safari plays through the WebKit GPU process, which bears no Safari bundle ID.
        let members = AudioProcessList.members(of: .app(bundleID: "com.apple.Safari"), in: processes,
                                               appPIDs: [300], ownPID: 1)
        #expect(members.map(\.id) == [3])
    }

    @Test func processesByPID() {
        let members = AudioProcessList.members(of: .processes([600]), in: processes, appPIDs: [], ownPID: 1)
        #expect(members.map(\.id) == [6])
    }

    @Test func systemLeavesOutOnlyThisProcess() {
        let members = AudioProcessList.members(of: .system, in: processes, appPIDs: [], ownPID: 400)
        #expect(members.map(\.id) == [4])
    }

    @Test func permissionErrorReadsAsFourLetters() {
        #expect(fourCC(kAudioDevicePermissionsError) == "'!hog' (\(kAudioDevicePermissionsError))")
        #expect(fourCC(-50) == "-50")
    }
}

@Suite struct TapMixTests {
    @Test func interleavedStereoAverages() {
        var samples: [Float] = [1, 0, 0.5, 0.5, -1, 1]
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        samples.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            var mono = [Float](repeating: 9, count: 3)
            TapReader.mix(list, frames: 3, channelsPerBuffer: 2, into: &mono)
            #expect(mono == [0.5, 0.5, 0])
        }
    }

    @Test func separateChannelsAverage() {
        var left: [Float] = [1, 1], right: [Float] = [0, -1]
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                var mono = [Float](repeating: 0, count: 2)
                TapReader.mix(list, frames: 2, channelsPerBuffer: 1, into: &mono)
                #expect(mono == [0.5, 0])
            }
        }
    }
}

@Suite struct SyncTests {
    /// Clicks every second into a detector, in blocks of 1600 samples whose
    /// host times run `ppm` faster than the sample count.
    private func clicks(seconds: Int, delay: Double, ppm: Double, level: Float = 0.2) -> ClickDetector {
        let detector = ClickDetector()
        let rate = 16_000.0
        let block = 1600
        let start = HostTime.ticks(1000)
        var samples = [Float](repeating: 0, count: block)
        for n in 0..<(seconds * 10) {
            for i in 0..<block {
                let t = Double(n * block + i) / rate - delay
                let inClick = t >= 0 && t.truncatingRemainder(dividingBy: 1) < 0.004
                samples[i] = inClick ? level : 0.0001 * Float((i % 7) - 3)
            }
            let hostSeconds = Double(n * block) / rate * (1 + ppm / 1e6)
            samples.withUnsafeBufferPointer { detector.receive($0, hostTime: start + HostTime.ticks(hostSeconds)) }
        }
        return detector
    }

    @Test func findsEveryClick() {
        let detector = clicks(seconds: 30, delay: 0.25, ppm: 0)
        #expect(detector.onsets.count == 30)
        #expect(abs(detector.onsets[0].host - HostTime.seconds(HostTime.ticks(1000)) - 0.25) < 0.001)
    }

    @Test func constantOffsetIsNoDrift() throws {
        let sys = clicks(seconds: 120, delay: 0.1, ppm: 0), mic = clicks(seconds: 120, delay: 0.135, ppm: 0)
        let analysis = try #require(SyncAnalysis.analyze(reference: sys.onsets.map(\.host), other: mic.onsets.map(\.host)))
        #expect(analysis.pairs.count == 120)
        #expect(abs(analysis.startOffset - 0.035) < 0.001)
        #expect(abs(analysis.drift) < 0.001)
    }

    @Test func clockSkewShowsByCountNotByHost() throws {
        // The mic's host times run 100 ppm away from its sample count: the
        // two ways to time a sample part by 60 ms in 10 minutes.
        let sys = clicks(seconds: 600, delay: 0.1, ppm: 0), mic = clicks(seconds: 600, delay: 0.1, ppm: 100)
        let byHost = try #require(SyncAnalysis.analyze(reference: sys.onsets.map(\.host), other: mic.onsets.map(\.host)))
        let byCount = try #require(SyncAnalysis.analyze(reference: sys.onsets.map(\.counted),
                                                        other: mic.onsets.map(\.counted)))
        // Medians of the first and last 30 pairs: 570 s apart.
        #expect(abs(byHost.drift - 0.057) < 0.002)
        #expect(abs(byCount.drift) < 0.002)
        #expect(abs(byHost.slopePerHour - 0.36) < 0.01)
    }

    @Test func pairsAcrossAMissingClick() throws {
        let reference = (0..<100).map(Double.init)
        let other = reference.filter { $0 != 50 }.map { $0 + 0.04 + $0 * 0.0002 }
        let analysis = try #require(SyncAnalysis.analyze(reference: reference, other: other, edge: 10))
        #expect(analysis.pairs.count == 99)
        #expect(analysis.unpaired == 1)
        #expect(abs(analysis.drift - 0.018) < 0.002)
        #expect(analysis.maxResidual < 0.001)
    }

    @Test func echoFindsTheDelayedCopy() throws {
        var generator = SystemRandomNumberGenerator()
        let rate = 16_000
        // Speech-like: noise bursts of 200 ms with pauses.
        let system = (0..<(rate * 6)).map { i -> Float in
            (i / 3200) % 2 == 0 ? Float.random(in: -0.5...0.5, using: &generator) : 0
        }
        let delay = 800 // 50 ms
        let mic = (0..<system.count).map { i -> Float in
            (i >= delay ? system[i - delay] * 0.1 : 0) + Float.random(in: -0.001...0.001, using: &generator)
        }
        let start = HostTime.ticks(10)
        let measure = try #require(EchoMeasure.measure(system: (start, system), mic: (start, mic)))
        #expect(abs(measure.lag - 0.05) < 0.002)
        #expect(measure.envelopeCorrelation > 0.9)
        #expect(measure.micDB - measure.systemDB < -10)
        #expect(measure.micQuietDB < measure.micDB - 20)
    }
}

@Suite struct SegmentTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "perekey-segments-\(UUID().uuidString)")
    }

    private func sine(_ count: Int) -> [Float] {
        (0..<count).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.3 }
    }

    @Test(arguments: SegmentFormat.allCases)
    func rotatesAndRecordsEachSegment(format: SegmentFormat) throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = HostTime.ticks(500)
        let store = try RecordingStore(directory: dir, startHostTime: start, format: format)
        let writer = SegmentWriter(track: "mic", store: store, format: format, segmentSeconds: 1)
        let block = sine(1600)
        for n in 0..<25 { // 2.5 s
            block.withUnsafeBufferPointer { writer.receive($0, hostTime: start + HostTime.ticks(Double(n) / 10)) }
        }
        writer.finish()
        store.setState(.stopped)
        #expect(writer.error == nil)

        let data = try Data(contentsOf: dir.appending(path: "meta.json"))
        let meta = try JSONDecoder().decode(RecordingMeta.self, from: data)
        #expect(meta.state == .stopped)
        #expect(meta.segments.map(\.file) == ["mic-0001", "mic-0002", "mic-0003"].map { "\($0).\(format.fileExtension)" })
        #expect(meta.segments.map(\.frames) == [16_000, 16_000, 8_000])
        #expect(meta.segments.allSatisfy { $0.closed })
        #expect(meta.segments.map { ($0.startOffset * 10).rounded() / 10 } == [0, 1, 2])
        #expect(meta.segments[1].startHostTime == start + HostTime.ticks(1))
        for segment in meta.segments {
            let file = try AVAudioFile(forReading: dir.appending(path: segment.file))
            #expect(file.fileFormat.sampleRate == 16_000)
            #expect(file.fileFormat.channelCount == 1)
            // AAC adds priming and padding; PCM is exact.
            #expect(format == .pcm ? file.length == segment.frames : abs(file.length - segment.frames) <= 4096)
        }
    }

    @Test func gapClosesTheSegmentAndIsRecorded() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = mach_absolute_time()
        let store = try RecordingStore(directory: dir, startHostTime: start, format: .pcm)
        let writer = SegmentWriter(track: "sys", store: store, format: .pcm, segmentSeconds: 60)
        let block = sine(1600)
        block.withUnsafeBufferPointer { writer.receive($0, hostTime: start) }
        writer.captureInterrupted(.deviceChanged)
        block.withUnsafeBufferPointer { writer.receive($0, hostTime: start + HostTime.ticks(2)) }
        writer.finish()
        let meta = store.snapshot
        #expect(meta.segments.count == 2)
        #expect(meta.segments.map(\.frames) == [1600, 1600])
        #expect(abs(meta.segments[1].startOffset - 2) < 0.001)
        #expect(meta.gaps.count == 1)
        #expect(meta.gaps[0].track == "sys")
        #expect(meta.gaps[0].reason == "deviceChanged")
    }

    @Test func metaKeepsThePlanKeys() throws {
        var meta = RecordingMeta(startHostTime: 7, format: "m4a")
        meta.segments = [.init(track: "mic", file: "mic-0001.m4a", startHostTime: 9, startOffset: 0.5, frames: 3,
                               closed: true)]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meta)) as? [String: Any]
        let segment = try #require((json?["segments"] as? [[String: Any]])?.first)
        #expect(Set(segment.keys).isSuperset(of: ["track", "startHostTime", "startOffset", "frames"]))
        #expect(json?["state"] as? String == "recording")
    }
}
