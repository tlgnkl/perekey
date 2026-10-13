// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CoreAudio
import Foundation
import os

/// Hidden checks of the voice layer that need the app's own permissions. They
/// run inside the signed app, so macOS (TCC) asks for and remembers the
/// microphone as Perekey's, not the terminal's:
///
///     open -n -W Perekey.app --args --voice-check mic [--cycles 1000] [--device <uid>]
///
/// `open` matters: a binary started from a shell gets the shell's permissions.
/// Each check prints its lines and writes them to a report file
/// (`--report <path>`, by default ~/Library/Logs/Perekey/voice-check-<name>.txt).
/// Exit status: 0 passed, 1 failed, 2 bad arguments, 3 no access (microphone,
/// system audio or screen recording).
public struct VoiceCheck: Sendable {
    /// A check: its name after `--voice-check`, the options it takes, and the run.
    public struct Command: Sendable {
        public let name: String
        public let summary: String
        public let options: [String]
        public let run: @Sendable (VoiceCheckOptions, VoiceCheckReport) async -> Int32

        public init(name: String, summary: String, options: [String],
                    run: @escaping @Sendable (VoiceCheckOptions, VoiceCheckReport) async -> Int32) {
            self.name = name
            self.summary = summary
            self.options = options
            self.run = run
        }
    }

    /// The checks. A new one adds itself here.
    public static let commands: [Command] = [.devices, .mic] + Command.systemAudio

    public let command: Command?
    public let options: VoiceCheckOptions
    let problem: String?

    /// Nil when the arguments do not ask for a check: the app starts as usual.
    public init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--voice-check") else { return nil }
        let rest = Array(arguments[(flag + 1)...])
        guard let name = rest.first, let command = Self.commands.first(where: { $0.name == name }) else {
            self.command = nil
            options = VoiceCheckOptions([:])
            problem = "unknown check \(rest.first.map { "'\($0)'" } ?? "(none)")"
            return
        }
        self.command = command
        var values: [String: String] = [:]
        var problem: String?
        var i = 1
        while i < rest.count {
            let key = rest[i]
            guard key.hasPrefix("--"), command.options.contains(String(key.dropFirst(2))) || key == "--report" else {
                problem = "\(name) takes no option '\(key)'"
                break
            }
            guard i + 1 < rest.count else {
                problem = "\(key) needs a value"
                break
            }
            values[String(key.dropFirst(2))] = rest[i + 1]
            i += 2
        }
        options = VoiceCheckOptions(values)
        self.problem = problem
    }

    /// Runs the check and returns the process exit status.
    public func run() async -> Int32 {
        guard let command, problem == nil else {
            print("perekey --voice-check: \(problem ?? "bad arguments")")
            for command in Self.commands {
                let options = (command.options + ["report"]).map { "[--\($0) …]" }.joined(separator: " ")
                print("  --voice-check \(command.name) \(options)\n      \(command.summary)")
            }
            return 2
        }
        let report = VoiceCheckReport(path: options.string("report") ?? VoiceCheckReport.defaultPath(command.name))
        report.line("perekey --voice-check \(command.name) \(options.description)")
        let status = await command.run(options, report)
        report.line("result: \(status == 0 ? "PASS" : status == 3 ? "NO ACCESS" : "FAIL") (exit \(status))")
        report.line("report: \(report.path)")
        return status
    }
}

public struct VoiceCheckOptions: Sendable, CustomStringConvertible {
    private let values: [String: String]

    init(_ values: [String: String]) {
        self.values = values
    }

    public func string(_ key: String) -> String? { values[key] }

    public func int(_ key: String, default value: Int) -> Int {
        values[key].flatMap(Int.init) ?? value
    }

    public var description: String {
        values.keys.sorted().map { "--\($0) \(values[$0]!)" }.joined(separator: " ")
    }
}

/// The lines of a check, to stdout and to the report file as they come.
public final class VoiceCheckReport: Sendable {
    public let path: String
    private let file = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)

    init(path: String) {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        file.withLockUnchecked { $0 = FileHandle(forWritingAtPath: path) }
    }

    static func defaultPath(_ name: String) -> String {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Perekey/voice-check-\(name).txt")
        return logs.path
    }

    public func line(_ text: String) {
        let data = Data((text + "\n").utf8)
        FileHandle.standardOutput.write(data)
        file.withLockUnchecked { $0?.write(data) }
    }
}

extension VoiceCheck.Command {
    static let devices = Self(name: "devices", summary: "lists the microphones", options: []) { _, report in
        let system = MicrophoneList.systemDefault()
        for mic in MicrophoneList.all() {
            let marks = [mic == system ? "system" : nil,
                         MicrophoneList.isRunningSomewhere(mic.id) ? "running" : nil].compactMap { $0 }
            report.line("\(mic.uid)\t\(mic.name)\(marks.isEmpty ? "" : "\t(\(marks.joined(separator: ", ")))")")
        }
        return 0
    }

    /// Access, 3 s of level, a device switch, then start/stop cycles with a
    /// random 0–50 ms between them; at the end no microphone may be running.
    static let mic = Self(name: "mic",
                          summary: "microphone access, level, device switch, start/stop cycles",
                          options: ["cycles", "device", "seconds", "wait-access"]) { options, report in
        await MicCheck(options: options, report: report).run()
    }
}

struct MicCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    func run() async -> Int32 {
        guard await access() else { return 3 }
        let system = MicrophoneList.systemDefault()
        for mic in MicrophoneList.all() {
            report.line("microphone: \(mic.name) [\(mic.uid)]\(mic == system ? " (system)" : "")")
        }
        let uid = options.string("device")
        if let uid, MicrophoneList.device(uid: uid) == nil {
            report.line("FAIL: no microphone with UID \(uid)")
            return 1
        }
        let capture = AudioCapture(preferredUID: uid)
        var used = Set<AudioDeviceID>()
        var passed = true
        passed = await level(capture, used: &used) && passed
        passed = await switchDevices(capture, used: &used) && passed
        passed = await cycles(capture, used: &used) && passed
        passed = await allOff(capture, used: used) && passed
        return passed ? 0 : 1
    }

    func access() async -> Bool {
        let waitSeconds = options.int("wait-access", default: 30)
        switch MicrophoneAccess.status {
        case .authorized:
            report.line("access: granted")
            return true
        case .notDetermined:
            report.line("access: not asked yet; macOS shows its prompt, waiting up to \(waitSeconds) s for a click")
            switch await requestAccess(waitingAtMost: waitSeconds) {
            case true?:
                report.line("access: granted now")
                return true
            case false?:
                report.line("access: denied in the prompt")
            case nil:
                report.line("access: no click in \(waitSeconds) s; click Allow in the macOS prompt and run again")
            }
            return false
        default:
            report.line("access: denied or restricted; turn Perekey on in System Settings → Privacy & Security → Microphone")
            return false
        }
    }

    /// The answer to the macOS prompt, or nil when nobody clicked in time. The
    /// prompt's callback may never come, so it races a timer instead of being awaited.
    private func requestAccess(waitingAtMost seconds: Int) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Bool?) -> Void = { value in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first {
                    continuation.resume(returning: value)
                }
            }
            AVCaptureDevice.requestAccess(for: .audio) { answer($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { answer(nil) }
        }
    }

    /// Audio for a few seconds: blocks come at the expected rate, with rising
    /// host times, and they are not all zero (silence is what macOS gives an
    /// app without the audio input entitlement).
    private func level(_ capture: AudioCapture, used: inout Set<AudioDeviceID>) async -> Bool {
        let seconds = options.int("seconds", default: 3)
        let meter = LevelMeter()
        let token: AudioSubscription
        do {
            token = try await capture.subscribe(meter)
        } catch {
            report.line("FAIL level: the microphone did not start: \(error)")
            return false
        }
        if let device = await capture.activeDevice {
            used.insert(device.id)
            report.line("level: reading \(device.name), dot on: \(MicrophoneList.isRunningSomewhere(device.id))")
        }
        for _ in 0..<(seconds * 2) {
            try? await Task.sleep(for: .milliseconds(500))
            let window = meter.takeWindow()
            report.line(String(format: "level: rms %6.1f dBFS, peak %6.1f dBFS, %5ld samples",
                               window.rmsDB, window.peakDB, window.count))
        }
        await capture.unsubscribe(token)
        let total = meter.total
        let expected = seconds * 16_000
        report.line("level: \(total.samples) samples in \(seconds) s (expected ≈ \(expected)), \(total.blocks) blocks, "
            + "host time always rising: \(total.hostTimeRising), peak \(String(format: "%.1f", total.peakDB)) dBFS")
        var ok = true
        if Double(total.samples) < Double(expected) * 0.8 {
            report.line("FAIL level: too few samples")
            ok = false
        }
        if total.peak == 0 {
            report.line("FAIL level: digital silence (no audio input entitlement, or no access)")
            ok = false
        }
        if !total.hostTimeRising {
            report.line("FAIL level: host times went back")
            ok = false
        }
        return ok
    }

    /// `kAudioOutputUnitProperty_CurrentDevice` while capture runs: to every
    /// other microphone, and to a private aggregate of the system one (a
    /// second device that every Mac has), then back.
    private func switchDevices(_ capture: AudioCapture, used: inout Set<AudioDeviceID>) async -> Bool {
        guard let system = MicrophoneList.systemDefault() else {
            report.line("FAIL switch: no system microphone")
            return false
        }
        let aggregate = PrivateAggregate(wrapping: system)
        defer { aggregate?.destroy() }
        let wrapped = aggregate?.microphone
        var targets = MicrophoneList.all().filter { $0.id != system.id && $0.uid != aggregate?.uid }
        report.line("switch: \(targets.count) other microphones besides the system one"
            + (wrapped == nil ? "; could not make a private aggregate device" : ", plus a private aggregate of it"))
        if let wrapped {
            targets.append(wrapped)
        }
        let start = await capture.preferredUID
        let meter = LevelMeter()
        guard let token = try? await capture.subscribe(meter) else {
            report.line("FAIL switch: the microphone did not start")
            return false
        }
        var ok = true
        for target in targets + [MicrophoneList.device(uid: start ?? system.uid) ?? system] {
            await capture.selectMicrophone(uid: target.uid)
            _ = meter.takeWindow()
            try? await Task.sleep(for: .milliseconds(700))
            let window = meter.takeWindow()
            let active = await capture.activeDevice
            let running = MicrophoneList.isRunningSomewhere(target.id)
            let fine = active?.id == target.id && running && window.count > 0
            if let active {
                used.insert(active.id)
            }
            report.line("switch: → \(target.name) [\(target.uid)]: AUHAL reads \(active?.name ?? "nothing"), "
                + "running \(running), \(window.count) samples, peak \(String(format: "%.1f", window.peakDB)) dBFS"
                + (fine ? "" : " — FAIL"))
            ok = ok && fine
        }
        await capture.unsubscribe(token)
        await capture.selectMicrophone(uid: start)
        return ok
    }

    /// Subscribe, wait 0–50 ms, unsubscribe, many times. A dictation tapped
    /// on and off fast does this.
    private func cycles(_ capture: AudioCapture, used: inout Set<AudioDeviceID>) async -> Bool {
        let count = options.int("cycles", default: 1000)
        let footprintBefore = footprintMegabytes()
        var failures = 0
        var startTimes: [Double] = []
        startTimes.reserveCapacity(count)
        var heard = 0
        let clock = ContinuousClock()
        for cycle in stride(from: 1, through: count, by: 1) {
            let meter = LevelMeter()
            let started = clock.now
            do {
                let token = try await capture.subscribe(meter)
                startTimes.append((clock.now - started) / .milliseconds(1))
                if let device = await capture.activeDevice {
                    used.insert(device.id)
                }
                try? await Task.sleep(for: .milliseconds(Int.random(in: 0...50)))
                await capture.unsubscribe(token)
                if meter.total.samples > 0 {
                    heard += 1
                }
            } catch {
                failures += 1
                if failures <= 5 {
                    report.line("cycles: #\(cycle) did not start: \(error)")
                }
            }
            if cycle % 100 == 0 {
                report.line("cycles: \(cycle)/\(count), \(failures) failed")
            }
        }
        startTimes.sort()
        func percentile(_ p: Double) -> Double {
            startTimes.isEmpty ? 0 : startTimes[min(startTimes.count - 1, Int(Double(startTimes.count) * p))]
        }
        report.line(String(format: "cycles: %ld, failed %ld, with audio %ld; start ms p50 %.1f, p95 %.1f, max %.1f; "
            + "footprint %.0f → %.0f MB", count, failures, heard, percentile(0.5), percentile(0.95),
            startTimes.last ?? 0, footprintBefore, footprintMegabytes()))
        return failures == 0
    }

    /// No microphone this check touched runs: the orange dot is off. Holds
    /// only while no other app uses a microphone.
    private func allOff(_ capture: AudioCapture, used: Set<AudioDeviceID>) async -> Bool {
        try? await Task.sleep(for: .milliseconds(500))
        let capturing = await capture.isRunning
        var ok = !capturing
        let subscribers = await capture.subscriberCount
        report.line("end: AudioCapture running \(capturing), subscribers \(subscribers)")
        for mic in MicrophoneList.all() where used.contains(mic.id) {
            let running = MicrophoneList.isRunningSomewhere(mic.id)
            report.line("end: \(mic.name): kAudioDevicePropertyDeviceIsRunningSomewhere = \(running)"
                + (running ? " — FAIL (or another app has it open)" : ""))
            ok = ok && !running
        }
        return ok
    }

    /// The process's memory as Activity Monitor shows it.
    private func footprintMegabytes() -> Double {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : 0
    }
}

/// RMS and peak of what a check hears.
final class LevelMeter: AudioSink, @unchecked Sendable {
    struct Window {
        var count = 0
        var sumSquares = 0.0
        var peak: Float = 0
        var rmsDB: Double { count == 0 ? -.infinity : 10 * log10(max(sumSquares / Double(count), 1e-20)) }
        var peakDB: Double { 20 * log10(Double(max(peak, 1e-10))) }
    }

    struct Total {
        var samples = 0
        var blocks = 0
        var peak: Float = 0
        var hostTimeRising = true
        var lastHostTime: UInt64 = 0
        var peakDB: Double { 20 * log10(Double(max(peak, 1e-10))) }
    }

    private let state = OSAllocatedUnfairLock(initialState: (window: Window(), total: Total()))

    func receive(_ samples: UnsafeBufferPointer<Float>, hostTime: UInt64) {
        var window = Window()
        for sample in samples {
            window.sumSquares += Double(sample * sample)
            window.peak = max(window.peak, abs(sample))
        }
        window.count = samples.count
        let measured = window
        state.withLock { state in
            state.window.count += measured.count
            state.window.sumSquares += measured.sumSquares
            state.window.peak = max(state.window.peak, measured.peak)
            state.total.samples += measured.count
            state.total.blocks += 1
            state.total.peak = max(state.total.peak, measured.peak)
            if hostTime <= state.total.lastHostTime {
                state.total.hostTimeRising = false
            }
            state.total.lastHostTime = hostTime
        }
    }

    func takeWindow() -> Window {
        state.withLock { state in
            defer { state.window = Window() }
            return state.window
        }
    }

    var total: Total { state.withLock { $0.total } }
}

/// An aggregate device of one microphone, seen only by this process: a second
/// input device to switch to on a Mac with one microphone.
private struct PrivateAggregate {
    let id: AudioDeviceID
    let uid: String

    init?(wrapping mic: Microphone) {
        let uid = "app.perekey.voice-check.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "Perekey check (\(mic.name))",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: mic.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: mic.uid]],
        ]
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr else { return nil }
        self.id = id
        self.uid = uid
    }

    var microphone: Microphone? {
        // A new aggregate takes a moment to show its streams.
        for _ in 0..<20 {
            if let mic = MicrophoneList.device(uid: uid) {
                return mic
            }
            usleep(50_000)
        }
        return nil
    }

    func destroy() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}
