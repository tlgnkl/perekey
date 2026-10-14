// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreAudio
import Foundation
import os
import PerekeyVoiceCore
import ScreenCaptureKit

// Hidden checks of the system audio of a call: the process tap, its
// permission, the time between the tracks, the echo, a device change, the
// segments on disk, and ScreenCaptureKit as the other way in. The tap's
// permission ("System Audio Recording") belongs to the app, so they run
// inside it like the microphone check:
//
//     open -n -W Perekey.app --args --voice-check sys-tap --source system --seconds 20
//
// `segments` and `seg-read` need no permission and run from a shell too.

extension VoiceCheck.Command {
    static let systemAudio: [Self] = [.sysProcs, .sysTap, .sysSync, .sysEcho, .sysRoute, .segments, .segRead, .sck]

    static let sysProcs = Self(name: "sys-procs", summary: "lists the processes Core Audio knows, and an app's helpers",
                               options: ["app"]) { options, report in
        let all = AudioProcessList.all()
        for process in all {
            report.line("process: \(process.id)\t\(process)")
        }
        if let app = options.string("app") {
            let pids = AudioProcessList.appPIDs(bundleID: app)
            let members = AudioProcessList.members(of: .app(bundleID: app), in: all, appPIDs: pids, ownPID: getpid())
            report.line("app \(app): running as \(pids.sorted()), \(members.count) audio processes: "
                + members.map(\.description).joined(separator: "; "))
        }
        return 0
    }

    /// Taps a source for a while, writes it in segments and reports the level
    /// each second. With `--play` it plays a file with afplay, again and again.
    static let sysTap = Self(name: "sys-tap",
                             summary: "taps an app (bundle ID), pid:<n> or system; level, helpers, zeros, segments",
                             options: ["source", "seconds", "play", "matching", "format", "segment", "out"]) { options, report in
        guard #available(macOS 14.2, *) else { return tapUnavailable(report) }
        return await TapCheck(options: options, report: report).run()
    }

    /// Clicks from the speakers into both tracks for `--minutes`: the drift
    /// between the microphone and the tap on the host clock.
    static let sysSync = Self(name: "sys-sync",
                              summary: "drift of the microphone against the tap over --minutes of clicks from the speakers",
                              options: ["minutes", "interval", "format", "segment", "out", "wait-access"]) { options, report in
        guard #available(macOS 14.2, *) else { return tapUnavailable(report) }
        return await SyncCheck(options: options, report: report).run()
    }

    static let sysEcho = Self(name: "sys-echo",
                              summary: "how much of the system audio the microphone hears, without and with voice processing",
                              options: ["seconds", "label", "play", "out", "wait-access"]) { options, report in
        guard #available(macOS 14.2, *) else { return tapUnavailable(report) }
        return await EchoCheck(options: options, report: report).run()
    }

    static let sysRoute = Self(name: "sys-route",
                               summary: "records the system audio across output device changes (--simulate switches by itself)",
                               options: ["seconds", "simulate", "play", "format", "segment", "out"]) { options, report in
        guard #available(macOS 14.2, *) else { return tapUnavailable(report) }
        return await RouteCheck(options: options, report: report).run()
    }

    static let segments = Self(name: "segments",
                               summary: "writes a sine in real time to segments (for kill -9); no permission needed",
                               options: ["seconds", "segment", "format", "out"]) { options, report in
        await SegmentsCheck(options: options, report: report).write()
    }

    static let segRead = Self(name: "seg-read", summary: "reads the segments of a recording directory",
                              options: ["dir"]) { options, report in
        SegmentsCheck(options: options, report: report).read()
    }

    static let sck = Self(name: "sck",
                          summary: "ScreenCaptureKit with captureMicrophone: permission, audio and microphone levels",
                          options: ["seconds", "play"]) { options, report in
        await ScreenCaptureCheck(options: options, report: report).run()
    }
}

// MARK: Shared parts

/// Process taps came in macOS 14.2.
private func tapUnavailable(_ report: VoiceCheckReport) -> Int32 {
    report.line("FAIL: process taps need macOS 14.2")
    return 1
}

extension VoiceCheckOptions {
    func double(_ key: String, default value: Double) -> Double {
        string(key).flatMap(Double.init) ?? value
    }

    /// `--out`, else a directory of its own under ~/Library/Logs/Perekey.
    func outDirectory(_ check: String) -> URL {
        if let path = string("out") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return URL(fileURLWithPath: VoiceCheckReport.defaultPath(check)).deletingPathExtension()
            .appending(path: stamp)
    }

    func segmentFormat() -> SegmentFormat {
        string("format").flatMap(SegmentFormat.init(rawValue:)) ?? .adts
    }

    func source() -> SystemAudioSource? {
        guard let value = string("source"), value != "system" else { return .system }
        if value.hasPrefix("pid:") {
            return Int32(value.dropFirst(4)).map { .processes([$0]) }
        }
        return .app(bundleID: value)
    }
}

/// Several sinks behind one.
final class FanOut: AudioSink, @unchecked Sendable {
    private let sinks: [any AudioSink]

    init(_ sinks: [any AudioSink]) {
        self.sinks = sinks
    }

    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        for sink in sinks {
            sink.receive(samples, hostTime: hostTime)
        }
    }

    func captureInterrupted(_ reason: AudioCaptureInterruption) {
        for sink in sinks {
            sink.captureInterrupted(reason)
        }
    }
}

/// `afplay` playing a file, over and over until stopped.
final class Player: @unchecked Sendable {
    private let file: String
    private let lock = OSAllocatedUnfairLock(initialState: (process: Process?.none, stopped: false, plays: 0))

    init(file: String) {
        self.file = file
    }

    var pid: pid_t? { lock.withLockUnchecked { $0.process?.processIdentifier } }
    var plays: Int { lock.withLock { $0.plays } }

    /// Starts afplay; `loop` starts it again each time it ends.
    func start(loop: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [file]
        process.terminationHandler = { [weak self] _ in
            guard loop, let self, !self.lock.withLock({ $0.stopped }) else { return }
            try? self.start(loop: true)
        }
        try process.run()
        lock.withLockUnchecked {
            $0.process = process
            $0.plays += 1
        }
    }

    var isPlaying: Bool { lock.withLockUnchecked { $0.process?.isRunning ?? false } }

    func stop() {
        let process = lock.withLockUnchecked { state in
            state.stopped = true
            return state.process
        }
        process?.terminate()
    }

    /// The process object of the running afplay, once it has opened the output.
    func audioObject(waitingAtMost seconds: Double) async -> pid_t? {
        let clock = ContinuousClock()
        let end = clock.now + .milliseconds(Int(seconds * 1000))
        while clock.now < end {
            if let pid, AudioProcessList.object(pid: pid) != nil {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

/// A spoken test file from `say`, made once per directory.
func speechFile(in directory: URL) -> String? {
    let url = directory.appending(path: "speech.aiff")
    if FileManager.default.fileExists(atPath: url.path) {
        return url.path
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = "Проверка записи системного звука. Говорит собеседник: раз, два, три, четыре, пять. "
        + "This is the other side of the call, speaking English for a while. "
        + "Теперь снова по-русски: шесть, семь, восемь, девять, десять."
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Milena", "-o", url.path, text]
    guard (try? say.run()) != nil else { return nil }
    say.waitUntilExit()
    return say.terminationStatus == 0 ? url.path : nil
}

func dB(_ value: Float) -> String {
    String(format: "%.1f", 20 * log10(Double(max(value, 1e-10))))
}

/// The tap's events as report lines.
func eventLogger(_ report: VoiceCheckReport, store: RecordingStore?) -> @Sendable (SystemAudioEvent) -> Void {
    { event in
        let at = store.map { String(format: "%.2f s: ", $0.offset(of: mach_absolute_time())) } ?? ""
        switch event {
        case .processes(let processes):
            report.line("tap: \(at)processes now \(processes.map(\.description).joined(separator: "; "))")
        case .rebuilt(let reason, let format, let gap):
            report.line(String(format: "tap: %@rebuilt after a change of %@, %@, audio gap %.0f ms", at, reason,
                               format, gap * 1000))
        case .silent(let seconds):
            report.line(String(format: "tap: %@WARNING only zeros for %.0f s while the source plays: "
                + "System Audio Recording is likely off for Perekey", at, seconds))
        case .sound:
            report.line("tap: \(at)sound again")
        case .failed(let message):
            report.line("tap: \(at)FAILED \(message)")
        }
    }
}

// MARK: sys-tap

@available(macOS 14.2, *)
private struct TapCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        guard let source = options.source() else {
            report.line("FAIL: --source takes system, a bundle ID or pid:<n>")
            return 2
        }
        let seconds = options.int("seconds", default: 20)
        let out = options.outDirectory("sys-tap")
        report.line("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), source \(source), out \(out.path)")
        let player = options.string("play").map { Player(file: ($0 as NSString).expandingTildeInPath) }
        if let player {
            do {
                try player.start(loop: true)
                _ = await player.audioObject(waitingAtMost: 3)
            } catch {
                report.line("FAIL: afplay: \(error)")
                return 1
            }
        }
        defer { player?.stop() }
        let format = options.segmentFormat()
        let store: RecordingStore
        do {
            store = try RecordingStore(directory: out, startHostTime: mach_absolute_time(), format: format)
        } catch {
            report.line("FAIL: \(out.path): \(error)")
            return 1
        }
        let writer = SegmentWriter(track: .sys, log: store, format: format,
                                   segmentSeconds: options.double("segment", default: 60))
        let meter = LevelMeter()
        let matching: SystemAudioTap.Matching = switch options.string("matching") {
        case "processes": .processes
        case "bundle-id": .bundleID
        case "both": .processesAndBundleID
        default: .automatic
        }
        report.line("tap: matching by \(matching); responsibility_get_pid_responsible_for_pid "
            + (AppHelpers.knowsResponsibility ? "found" : "missing"))
        let tap = SystemAudioTap(source: source, matching: matching,
                                 onEvent: eventLogger(report, store: store))
        let started = ContinuousClock.now
        do {
            try await tap.start(FanOut([writer, meter]))
        } catch let error as SystemAudioTapError {
            report.line("tap: did not start: \(error)")
            if case .notPermitted = error {
                return 3
            }
            return 1
        } catch {
            report.line("tap: did not start: \(error)")
            return 1
        }
        report.line(String(format: "tap: started in %.0f ms, format %@", (ContinuousClock.now - started) / .milliseconds(1),
                           describe(await tap.format)))
        report.line("tap: processes \(await tap.processes.map(\.description).joined(separator: "; "))")
        for second in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            let window = meter.takeWindow()
            let counts = await tap.counts
            let silent = await tap.silentSeconds
            let playing = AudioProcessList.all(withResponsibility: false).filter(\.isRunningOutput).map { $0.bundleID ?? "pid \($0.pid)" }
            report.line(String(format: "%3ld s: rms %6.1f dBFS, peak %6.1f dBFS, %ld blocks, zeros for %.0f s; playing: %@",
                               second, window.rmsDB, window.peakDB, counts.blocks, silent,
                               playing.joined(separator: ", ")))
        }
        await tap.stop()
        writer.finish()
        store.setState(.stopped)
        let total = meter.total
        let meta = store.snapshot
        report.line("segments: " + meta.segments.map { "\($0.file) \($0.frames) frames at \(String(format: "%.3f", $0.startOffset)) s" }
            .joined(separator: "; ") + (writer.error.map { "; error \($0)" } ?? ""))
        report.line("total: \(total.samples) samples, peak \(dB(total.peak)) dBFS, rebuilds \(await tap.rebuilds)")
        if total.samples == 0 {
            report.line("FAIL: no audio blocks came")
            return 1
        }
        if total.peak == 0 {
            report.line("FAIL: only zeros: System Audio Recording is off for Perekey, or the source was silent")
            return 3
        }
        return 0
    }
}

// MARK: sys-sync

@available(macOS 14.2, *)
private struct SyncCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        guard await MicCheck(options: options, report: report).access() else { return 3 }
        let minutes = options.double("minutes", default: 60)
        let interval = options.double("interval", default: 1)
        let out = options.outDirectory("sys-sync")
        let clicks = out.appending(path: "clicks.caf")
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try ClickTrack.write(to: clicks, minutes: minutes, interval: interval)
        } catch {
            report.line("FAIL: click file: \(error)")
            return 1
        }
        let volume = outputVolume()
        report.line("sync: \(minutes) min of clicks every \(interval) s from \(outputName()), volume \(volume.map { String(format: "%.0f%%", $0 * 100) } ?? "?"); out \(out.path)")
        let format = options.segmentFormat()
        let segment = options.double("segment", default: 300)
        let start = mach_absolute_time()
        let store: RecordingStore
        do {
            store = try RecordingStore(directory: out, startHostTime: start, format: format)
        } catch {
            report.line("FAIL: \(error)")
            return 1
        }
        // An hour without a key press must not put the Mac to sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "sys-sync")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let micClicks = ClickDetector(), sysClicks = ClickDetector()
        let micMeter = LevelMeter(), sysMeter = LevelMeter()
        let micWriter = SegmentWriter(track: .mic, log: store, format: format, segmentSeconds: segment)
        let sysWriter = SegmentWriter(track: .sys, log: store, format: format, segmentSeconds: segment)
        let capture = AudioCapture()
        let token: AudioSubscription
        do {
            token = try await capture.subscribe(FanOut([micWriter, micClicks, micMeter]))
        } catch {
            report.line("FAIL: the microphone did not start: \(error)")
            return 1
        }
        report.line("mic: \(await capture.activeDevice?.name ?? "?")")
        let player = Player(file: clicks.path)
        do {
            try player.start(loop: false)
        } catch {
            report.line("FAIL: afplay: \(error)")
            await capture.unsubscribe(token)
            return 1
        }
        guard let pid = await player.audioObject(waitingAtMost: 5) else {
            report.line("FAIL: afplay did not open the output")
            await capture.unsubscribe(token)
            return 1
        }
        let tap = SystemAudioTap(source: .processes([pid]), onEvent: eventLogger(report, store: store))
        do {
            try await tap.start(FanOut([sysWriter, sysClicks, sysMeter]))
        } catch {
            report.line("FAIL: the tap did not start: \(error)")
            player.stop()
            await capture.unsubscribe(token)
            return error as? SystemAudioTapError == nil ? 1 : 3
        }
        var minute = 0
        while player.isPlaying {
            try? await Task.sleep(for: .seconds(5))
            let elapsed = HostTime.seconds(mach_absolute_time() - start)
            guard Int(elapsed / 60) > minute || !player.isPlaying else { continue }
            minute = Int(elapsed / 60)
            let mic = micMeter.takeWindow(), sys = sysMeter.takeWindow()
            let analysis = SyncAnalysis.analyze(reference: sysClicks.onsets.map(\.host), other: micClicks.onsets.map(\.host))
            report.line(String(format: "%3ld min: clicks sys %ld, mic %ld; offset now %@; mic peak %@ dBFS, sys peak %@ dBFS",
                               minute, sysClicks.onsets.count, micClicks.onsets.count,
                               analysis.map { String(format: "%.1f ms", $0.endOffset * 1000) } ?? "—",
                               String(format: "%.1f", mic.peakDB), String(format: "%.1f", sys.peakDB)))
        }
        await tap.stop()
        await capture.unsubscribe(token)
        micWriter.finish()
        sysWriter.finish()
        store.setState(.stopped)
        return summarize(micClicks.onsets, sysClicks.onsets, store: store, out: out, interval: interval)
    }

    private func summarize(_ mic: [ClickDetector.Onset], _ sys: [ClickDetector.Onset], store: RecordingStore,
                           out: URL, interval: Double) -> Int32 {
        report.line("clicks: sys \(sys.count), mic \(mic.count)")
        let byHost = SyncAnalysis.analyze(reference: sys.map(\.host), other: mic.map(\.host))
        let byCount = SyncAnalysis.analyze(reference: sys.map(\.counted), other: mic.map(\.counted))
        for (name, analysis) in [("host time of each block", byHost), ("sample count from the first block", byCount)] {
            guard let analysis else {
                report.line("drift by \(name): no pairs")
                continue
            }
            report.line(String(format: "drift by %@: %ld pairs over %.1f min, %ld unpaired; mic − sys at start %.1f ms, "
                + "at end %.1f ms, drift %+.1f ms, slope %+.1f ms/h, max off the line %.1f ms",
                               name, analysis.pairs.count, analysis.span / 60, analysis.unpaired,
                               analysis.startOffset * 1000, analysis.endOffset * 1000, analysis.drift * 1000,
                               analysis.slopePerHour * 1000, analysis.maxResidual * 1000))
        }
        // Each track's own clock against the host: counted − host at the end.
        for (name, onsets) in [("sys", sys), ("mic", mic)] where onsets.count > 1 {
            let first = onsets.first!, last = onsets.last!
            let skew = (last.counted - last.host) - (first.counted - first.host)
            let span = last.host - first.host
            report.line(String(format: "%@ clock: sample count runs %+.1f ms against the host over %.1f min (%+.1f ppm)",
                               name, skew * 1000, span / 60, span > 0 ? skew / span * 1e6 : 0))
        }
        if sys.count > 1 {
            let spacing = (sys.last!.host - sys.first!.host) / Double(sys.count - 1)
            report.line(String(format: "sys: mean click spacing %.6f s (file: %.6f s)", spacing, interval))
        }
        let micLevel = mic.map(\.level).sorted(), sysLevel = sys.map(\.level).sorted()
        if !micLevel.isEmpty, !sysLevel.isEmpty {
            report.line("echo: median click peak sys \(dB(sysLevel[sysLevel.count / 2])) dBFS, "
                + "mic \(dB(micLevel[micLevel.count / 2])) dBFS")
        }
        var tsv = "sys_host\tmic_minus_sys_ms\n"
        for pair in byHost?.pairs ?? [] {
            tsv += String(format: "%.6f\t%.3f\n", pair.reference, pair.offset * 1000)
        }
        try? tsv.write(to: out.appending(path: "pairs.tsv"), atomically: true, encoding: .utf8)
        report.line("segments: \(store.snapshot.segments.count) in \(out.path), pairs in pairs.tsv")
        guard let byHost else {
            report.line("FAIL: the microphone did not hear the clicks: turn the volume up, speakers on")
            return 1
        }
        let ok = abs(byHost.drift) <= 0.05
        report.line(ok ? "drift within 50 ms" : "FAIL: drift over 50 ms")
        return ok ? 0 : 1
    }
}

func outputVolume() -> Float? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard let device: AudioDeviceID = MicrophoneList.value(system, kAudioHardwarePropertyDefaultOutputDevice) else {
        return nil
    }
    let main: Float32? = MicrophoneList.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              scope: kAudioDevicePropertyScopeOutput)
    return main
}

func outputName() -> String {
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard let device: AudioDeviceID = MicrophoneList.value(system, kAudioHardwarePropertyDefaultOutputDevice) else {
        return "?"
    }
    return MicrophoneList.string(device, kAudioObjectPropertyName) ?? "\(device)"
}

// MARK: sys-echo

@available(macOS 14.2, *)
private struct EchoCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        guard await MicCheck(options: options, report: report).access() else { return 3 }
        let seconds = options.int("seconds", default: 20)
        let label = options.string("label") ?? "speakers"
        let out = options.outDirectory("sys-echo")
        guard let file = options.string("play").map({ ($0 as NSString).expandingTildeInPath }) ?? speechFile(in: out) else {
            report.line("FAIL: no file to play")
            return 1
        }
        report.line("echo: \(label), output \(outputName()), volume \(outputVolume().map { String(format: "%.0f%%", $0 * 100) } ?? "?"), \(seconds) s per mode")
        var rows: [(String, EchoMeasure?)] = []
        for processing in [false, true] {
            let mode = processing ? "voice processing on" : "voice processing off"
            guard let (system, mic) = await record(seconds: seconds, file: file, voiceProcessing: processing) else {
                report.line("FAIL: \(mode): no audio")
                return 1
            }
            save(system, to: out.appending(path: "\(label)-sys.caf"))
            save(mic, to: out.appending(path: "\(label)-mic-\(processing ? "vp" : "plain").caf"))
            rows.append((mode, EchoMeasure.measure(system: system, mic: mic)))
        }
        report.line("| \(label) | system dBFS | mic while it plays | mic in pauses | envelope correlation | lag |")
        for (mode, measure) in rows {
            guard let m = measure else {
                report.line("| \(mode) | — | — | — | — | — |")
                continue
            }
            report.line(String(format: "| %@ | %.1f | %.1f | %.1f | %.2f | %.0f ms |", mode, m.systemDB, m.micDB,
                               m.micQuietDB, m.envelopeCorrelation, m.lag * 1000))
        }
        report.line("files: \(out.path)")
        return 0
    }

    /// The tap of afplay and the microphone for `seconds`, as two tracks.
    private func record(seconds: Int, file: String, voiceProcessing: Bool) async
        -> ((start: UInt64, samples: [Float]), (start: UInt64, samples: [Float]))? {
        let micTrack = TrackBuffer(), sysTrack = TrackBuffer()
        let capture = AudioCapture()
        var token: AudioSubscription?
        var engine: VoiceProcessingInput?
        if voiceProcessing {
            do {
                engine = try VoiceProcessingInput(sink: micTrack)
                report.line("voice processing: input \(engine!.formatDescription)")
            } catch {
                report.line("voice processing: did not start: \(error)")
                return nil
            }
        } else {
            token = try? await capture.subscribe(micTrack)
            guard token != nil else { return nil }
        }
        // Quiet first: the microphone's own floor.
        try? await Task.sleep(for: .seconds(2))
        let player = Player(file: file)
        try? player.start(loop: true)
        let tap: SystemAudioTap?
        if let pid = await player.audioObject(waitingAtMost: 3) {
            tap = SystemAudioTap(source: .processes([pid]), onEvent: eventLogger(report, store: nil))
            try? await tap?.start(sysTrack)
        } else {
            tap = nil
        }
        try? await Task.sleep(for: .seconds(seconds))
        player.stop()
        await tap?.stop()
        if let token {
            await capture.unsubscribe(token)
        }
        engine?.stop()
        let system = sysTrack.contents, mic = micTrack.contents
        guard !system.samples.isEmpty, !mic.samples.isEmpty else { return nil }
        return (system, mic)
    }

    private func save(_ track: (start: UInt64, samples: [Float]), to url: URL) {
        guard let file = try? AVAudioFile(forWriting: url, settings: SegmentFormat.pcm.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(track.samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(track.samples.count)
        track.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try? file.write(from: buffer)
    }
}

/// The microphone through `AVAudioEngine` with voice processing (Apple's echo
/// canceller) on the input node, for comparison only: `AudioCapture` does not
/// use it.
private final class VoiceProcessingInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    let formatDescription: String

    init(sink: any AudioSink) throws {
        let node = engine.inputNode
        try node.setVoiceProcessingEnabled(true)
        let format = node.outputFormat(forBus: 0)
        formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
        let resampler = try Resampler(inputRate: format.sampleRate)
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
            resampler.process(buffer, hostTime: hostTime) { sink.receive($0, hostTime: $1) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: sys-route

@available(macOS 14.2, *)
private struct RouteCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        let seconds = options.int("seconds", default: 120)
        let simulate = options.string("simulate") == "on"
        let out = options.outDirectory("sys-route")
        guard let file = options.string("play").map({ ($0 as NSString).expandingTildeInPath }) ?? speechFile(in: out) else {
            report.line("FAIL: no file to play")
            return 1
        }
        let format = options.segmentFormat()
        guard let store = try? RecordingStore(directory: out, startHostTime: mach_absolute_time(), format: format) else {
            report.line("FAIL: \(out.path)")
            return 1
        }
        let writer = SegmentWriter(track: .sys, log: store, format: format,
                                   segmentSeconds: options.double("segment", default: 60))
        let meter = LevelMeter()
        let player = Player(file: file)
        try? player.start(loop: true)
        defer { player.stop() }
        let tap = SystemAudioTap(source: .system, onEvent: eventLogger(report, store: store))
        do {
            try await tap.start(FanOut([writer, meter]))
        } catch {
            report.line("FAIL: the tap did not start: \(error)")
            return 1
        }
        report.line("route: output \(outputName()), \(seconds) s"
            + (simulate ? "; switching to a new output device and back by itself" : "; switch the output now and then"))
        var switcher: OutputSwitch?
        var lastOutput = outputName()
        for second in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            if simulate, second == 8 {
                switcher = OutputSwitch(report: report)
                switcher?.switchToCopy()
            }
            if simulate, second == 18 {
                switcher?.restore()
                switcher = nil
            }
            let window = meter.takeWindow()
            let output = outputName()
            if output != lastOutput {
                report.line("\(second) s: output is now \(output)")
                lastOutput = output
            }
            report.line(String(format: "%3ld s: %ld samples, peak %6.1f dBFS, running %@", second, window.count,
                               window.peakDB, String(await tap.isRunning)))
        }
        switcher?.restore()
        let rebuilds = await tap.rebuilds
        let running = await tap.isRunning
        await tap.stop()
        writer.finish()
        store.setState(.stopped)
        let meta = store.snapshot
        report.line("segments: " + meta.segments.map { "\($0.file) at \(String(format: "%.2f", $0.startOffset)) s, \($0.frames) frames" }
            .joined(separator: "; "))
        report.line("gaps: " + meta.gaps.map { "\($0.track.rawValue) at \(String(format: "%.2f", $0.startOffset)) s (\($0.reason.rawValue))" }
            .joined(separator: "; "))
        report.line("rebuilds \(rebuilds), still running at the end: \(running)")
        return running && (!simulate || rebuilds >= 2) ? 0 : 1
    }
}

/// Makes a new output device out of the current one (a public aggregate of
/// it), makes it the system output, and puts the old one back: an output
/// switch on a Mac with one output.
private final class OutputSwitch {
    private let report: VoiceCheckReport
    private var original = AudioDeviceID(kAudioObjectUnknown)
    private var copy = AudioDeviceID(kAudioObjectUnknown)

    init(report: VoiceCheckReport) {
        self.report = report
    }

    func switchToCopy() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let current: AudioDeviceID = MicrophoneList.value(system, kAudioHardwarePropertyDefaultOutputDevice),
              let uid = MicrophoneList.string(current, kAudioDevicePropertyDeviceUID) else { return }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "app.perekey.route-check.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Perekey route check",
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
        ]
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr else {
            report.line("route: could not make a second output device")
            return
        }
        original = current
        copy = id
        usleep(300_000)
        let status = setDefaultOutput(id)
        report.line("route: system output → Perekey route check: \(fourCC(status))")
    }

    func restore() {
        guard copy != kAudioObjectUnknown else { return }
        let status = setDefaultOutput(original)
        report.line("route: system output → back: \(fourCC(status))")
        usleep(300_000)
        AudioHardwareDestroyAggregateDevice(copy)
        copy = AudioDeviceID(kAudioObjectUnknown)
    }

    private func setDefaultOutput(_ id: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }
}

// MARK: segments, seg-read

private struct SegmentsCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    /// A 440 Hz sine in 100 ms blocks at the pace of real time, so a kill
    /// lands in the middle of a segment.
    func write() async -> Int32 {
        let seconds = options.double("seconds", default: 300)
        let format = options.segmentFormat()
        let out = options.outDirectory("segments")
        guard let store = try? RecordingStore(directory: out, startHostTime: mach_absolute_time(), format: format) else {
            report.line("FAIL: \(out.path)")
            return 1
        }
        let writer = SegmentWriter(track: .mic, log: store, format: format,
                                   segmentSeconds: options.double("segment", default: 60))
        report.line("segments: \(format.rawValue) into \(out.path), pid \(getpid())")
        let block = Int(VoiceCore.sampleRate / 10)
        var samples = [Float](repeating: 0, count: block)
        var phase = 0.0
        let clock = ContinuousClock()
        let start = clock.now
        for n in 0..<Int(seconds * 10) {
            for i in 0..<block {
                samples[i] = Float(sin(phase)) * 0.3
                phase += 2 * .pi * 440 / VoiceCore.sampleRate
            }
            samples.withUnsafeBufferPointer { writer.receive($0, hostTime: mach_absolute_time()) }
            if n % 100 == 99 {
                report.line("segments: \((n + 1) / 10) s written, \(writer.segmentCount) segments")
            }
            try? await clock.sleep(until: start + .milliseconds(100 * (n + 1)))
        }
        writer.finish()
        store.setState(.stopped)
        return writer.error == nil ? 0 : 1
    }

    /// Opens each audio file of `--dir` with AVAudioFile.
    func read() -> Int32 {
        guard let dir = options.string("dir").map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }) else {
            report.line("FAIL: --dir is required")
            return 2
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var unreadable = 0
        for name in files where [".m4a", ".caf", ".aac"].contains(where: { name.hasSuffix($0) }) {
            let url = dir.appending(path: name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            do {
                let file = try AVAudioFile(forReading: url)
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(max(1, file.length)))!
                var decoded = "not decoded"
                do {
                    try file.read(into: buffer)
                    decoded = "\(buffer.frameLength) decoded"
                } catch {
                    decoded = "decode error \(error.localizedDescription)"
                }
                report.line(String(format: "%@: %ld bytes, %lld frames (%.2f s), %@", name, size, file.length,
                                   Double(file.length) / file.fileFormat.sampleRate, decoded))
            } catch {
                unreadable += 1
                report.line("\(name): \(size) bytes, UNREADABLE: \((error as NSError).domain) \((error as NSError).code)")
            }
        }
        if let meta = try? RecordingStore.read(dir) {
            report.line("meta.json: state \(meta.state.rawValue), "
                + meta.segments.map { "\($0.file) \($0.closed ? "closed, \($0.frames) frames" : "open")" }.joined(separator: "; "))
        } else {
            report.line("meta.json: missing or unreadable")
        }
        return unreadable == 0 ? 0 : 1
    }
}

// MARK: sck

/// ScreenCaptureKit as the other way to the system audio: one stream with the
/// system audio and, on macOS 15+, the microphone. It needs "Screen & System
/// Audio Recording" (the screen part) and the microphone.
private struct ScreenCaptureCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        let seconds = options.int("seconds", default: 10)
        report.line("sck: CGPreflightScreenCaptureAccess \(CGPreflightScreenCaptureAccess())")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            let error = error as NSError
            report.line("sck: no shareable content: \(error.domain) \(error.code) \(error.localizedDescription)")
            return 3
        }
        guard let display = content.displays.first else {
            report.line("FAIL: no display")
            return 1
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        let output = ScreenCaptureOutput()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config,
                              delegate: nil)
        let queue = DispatchQueue(label: "app.perekey.voice-check.sck")
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            if #available(macOS 15.0, *) {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
        } catch {
            let error = error as NSError
            report.line("sck: did not start: \(error.domain) \(error.code) \(error.localizedDescription)")
            return 3
        }
        let player = options.string("play").map { Player(file: ($0 as NSString).expandingTildeInPath) }
        try? player?.start(loop: true)
        for second in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            let window = output.take()
            report.line(String(format: "%3ld s: audio %ld frames peak %@ dBFS; microphone %ld frames peak %@ dBFS",
                               second, window.audio.frames, dB(window.audio.peak), window.mic.frames, dB(window.mic.peak)))
        }
        player?.stop()
        try? await stream.stopCapture()
        let total = output.total
        report.line("sck: audio \(total.audio.frames) frames, peak \(dB(total.audio.peak)) dBFS; "
            + "microphone \(total.mic.frames) frames, peak \(dB(total.mic.peak)) dBFS")
        return total.audio.frames > 0 ? 0 : 1
    }
}

private final class ScreenCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Level {
        var frames = 0
        var peak: Float = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: (audio: Level(), mic: Level(), totalAudio: Level(), totalMic: Level()))

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen else { return }
        var level = Level()
        level.frames = CMSampleBufferGetNumSamples(sampleBuffer)
        try? sampleBuffer.withAudioBufferList { list, _ in
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    level.peak = max(level.peak, abs(data[i]))
                }
            }
        }
        let isMic = type.rawValue == 2 // .microphone, macOS 15+
        let measured = level
        state.withLock { state in
            if isMic {
                state.mic.frames += measured.frames
                state.mic.peak = max(state.mic.peak, measured.peak)
                state.totalMic.frames += measured.frames
                state.totalMic.peak = max(state.totalMic.peak, measured.peak)
            } else {
                state.audio.frames += measured.frames
                state.audio.peak = max(state.audio.peak, measured.peak)
                state.totalAudio.frames += measured.frames
                state.totalAudio.peak = max(state.totalAudio.peak, measured.peak)
            }
        }
    }

    func take() -> (audio: Level, mic: Level) {
        state.withLock { state in
            defer {
                state.audio = Level()
                state.mic = Level()
            }
            return (state.audio, state.mic)
        }
    }

    var total: (audio: Level, mic: Level) { state.withLock { ($0.totalAudio, $0.totalMic) } }
}
