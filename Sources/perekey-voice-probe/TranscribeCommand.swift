// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import Foundation
import os
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// `transcribe <recording> <model> [--diarize] [--dictation-every s --phrase audio] [--cancel-after s]`:
/// the app's file queue on a recording folder (`meta.json` and its segments,
/// or a file), with the store in `$PEREKEY_VOICE_MODELS`. Prints JSON: the
/// time of each phase, the peak memory, and with `--dictation-every`, how
/// long the queue took to stop for a dictation and how long the dictation
/// took on its own engine. The text is not printed; `transcript.json` is in
/// the folder.
enum TranscribeCommand {
    struct Dictation {
        var began: Double
        var paused: Double?
        var done: Double
    }

    static func run(_ arguments: [String]) async throws {
        var rest = arguments[...]
        guard let path = rest.popFirst(), let model = rest.popFirst() else {
            throw ProbeError.message(
                "transcribe <recording> <model> [--diarize] [--dictation-every s --phrase audio] [--cancel-after s]")
        }
        var diarize = false
        var every: Double?
        var phrasePath: String?
        var cancelAfter: Double?
        while let flag = rest.popFirst() {
            switch flag {
            case "--diarize": diarize = true
            case "--dictation-every": every = rest.popFirst().flatMap(Double.init)
            case "--phrase": phrasePath = rest.popFirst()
            case "--cancel-after": cancelAfter = rest.popFirst().flatMap(Double.init)
            default: throw ProbeError.message("unknown flag \(flag)")
            }
        }
        guard let root = ProcessInfo.processInfo.environment["PEREKEY_VOICE_MODELS"] else {
            throw ProbeError.message("set PEREKEY_VOICE_MODELS to the models folder")
        }
        let models = URL(filePath: root, directoryHint: .isDirectory)
        let store = VoiceModelStore(
            locations: VoiceModelLocations(models: models, managed: models.appending(path: "../managed").standardized,
                                           coreMLCache: models.appending(path: "../coreml-cache").standardized),
            managed: ManagedSettings())
        let recording = URL(filePath: path, directoryHint: .isDirectory).standardized
        guard let id = UUID(uuidString: recording.lastPathComponent) else {
            throw ProbeError.message("the recording folder is named by its UUID")
        }
        let folder = RecordingsFolder(root: recording.deletingLastPathComponent())
        let activity = DictationActivity()
        let opener = VoiceAudioOpener(scratch: recording.appending(path: "scratch", directoryHint: .isDirectory))
        let queue = FileTranscriber(environment: .init(
            folder: folder, opener: opener, detector: SileroVAD(store: store),
            makeEngine: { VoiceEngines.make(model: $0, store: store) },
            makeDiarizer: { VBxDiarizer(store: store, opener: opener) }, dictation: activity))

        // Dictation's own engine, as in the app, warmed up first.
        var phrase: AudioBuffer16k?
        var dictator: (any SpeechEngine)?
        if every != nil {
            guard let phrasePath else { throw ProbeError.message("--dictation-every needs --phrase") }
            phrase = AudioBuffer16k(try Engines.samples(phrasePath))
            let engine = FluidAudioEngine(id: "parakeet-tdt-v3", store: store)
            try await engine.prepare()
            _ = try await engine.transcribe(phrase!)
            dictator = engine
        }

        let meter = Footprint()
        meter.start()
        let clock = ContinuousClock.now
        @Sendable func now() -> Double {
            let elapsed = ContinuousClock.now - clock
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let marks = OSAllocatedUnfairLock(initialState: [(String, Double)]())
        let pauses = OSAllocatedUnfairLock(initialState: [Double]())
        let watcher = Task {
            var last = ""
            for await phases in queue.phases() {
                guard let phase = phases[id] else { continue }
                let name = switch phase {
                case .queued: "queued"
                case .preparingModel: "preparingModel"
                case .transcribing: "transcribing"
                case .waitingForDictation: "waitingForDictation"
                case .diarizing: "diarizing"
                case .done: "done"
                case let .failed(failure): "failed:\(failure)"
                case .cancelled: "cancelled"
                }
                if name == "waitingForDictation" { pauses.withLock { $0.append(now()) } }
                if name != last {
                    marks.withLock { $0.append((name, now())) }
                    last = name
                }
                if !phase.isPending { break }
            }
        }
        await queue.enqueue(TranscriptionJob(recording: id, model: model, diarize: diarize))

        var dictations: [Dictation] = []
        let engine = dictator
        let spoken = phrase
        let ticker: Task<[Dictation], Never>? = every.map { every in
            Task {
                var list: [Dictation] = []
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    guard queue.isBusy, let engine, let spoken else { break }
                    let began = now()
                    activity.began()
                    _ = try? await engine.transcribe(spoken)
                    let done = now()
                    // The text is in: the queue may go on.
                    activity.ended()
                    let paused = pauses.withLock { $0.first { $0 >= began } }
                    list.append(Dictation(began: began, paused: paused, done: done))
                }
                return list
            }
        }
        var cancelled: Double?
        if let cancelAfter {
            try await Task.sleep(for: .seconds(cancelAfter))
            cancelled = now()
            await queue.cancel(id)
        }
        await watcher.value
        let finished = now()
        ticker?.cancel()
        dictations = await ticker?.value ?? []
        await queue.shutdown()
        await dictator?.unload()
        let memory = meter.stop()

        var phases: [[String: Any]] = []
        let list = marks.withLock { $0 }
        for (index, mark) in list.enumerated() {
            let end = index + 1 < list.count ? list[index + 1].1 : finished
            phases.append(["phase": mark.0, "at_s": mark.1, "for_s": end - mark.1])
        }
        var json: [String: Any] = [
            "model": model, "diarize": diarize, "wall_s": finished, "phases": phases,
            "peak_footprint_mb": memory.footprintMB, "peak_rss_mb": memory.rssMB,
            "chip": Self.chip(), "memory_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
        ]
        if let cancelled { json["cancel_to_stop_s"] = finished - cancelled }
        if case let .loaded(meta) = folder.meta(id) {
            json["state"] = meta.state.rawValue
            json["audio_h"] = (meta.duration ?? 0) / 3600
        }
        if case let .loaded(document) = folder.transcript(id) {
            json["segments"] = document.segments.count
            json["words"] = document.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
            json["speakers"] = document.speakers.map(\.id)
        }
        if !dictations.isEmpty {
            let stops = dictations.compactMap { item in item.paused.map { $0 - item.began } }.sorted()
            let takes = dictations.map { $0.done - $0.began }.sorted()
            json["dictations"] = [
                "count": dictations.count, "queue_stopped": stops.count,
                "queue_stop_median_s": stops.isEmpty ? 0 : stops[stops.count / 2], "queue_stop_max_s": stops.last ?? 0,
                "dictation_median_s": takes[takes.count / 2], "dictation_max_s": takes.last ?? 0,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }
}

/// The process's peak memory: `phys_footprint` sampled five times a second,
/// and `ru_maxrss` at the end.
final class Footprint: @unchecked Sendable {
    private let peak = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var sampler: Task<Void, Never>?

    func start() {
        sampler = Task.detached { [peak] in
            while !Task.isCancelled {
                let now = Footprint.current()
                peak.withLock { $0 = max($0, now) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() -> (footprintMB: Double, rssMB: Double) {
        sampler?.cancel()
        let last = Footprint.current()
        let top = peak.withLock { max($0, last) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(top) / 1_048_576, Double(usage.ru_maxrss) / 1_048_576)
    }

    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
