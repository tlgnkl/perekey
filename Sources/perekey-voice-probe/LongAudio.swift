// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// `track <dir> <hours> <name> <audio[:rttm]>...`: a recording's track from
/// open audio, as the call recorder writes it: 16 kHz mono AAC in ADTS,
/// segments of 5 minutes, `meta.json`. The files follow one another and
/// repeat until the track is `hours` long. With RTTM files beside the audio
/// the track gets `<name>.rttm`, the speakers on the track's time.
enum TrackCommand {
    static let block = 1_600  // 0.1 s: segments of whole blocks

    static func run(_ arguments: [String]) throws {
        guard arguments.count >= 4, let hours = Double(arguments[1]) else {
            throw ProbeError.message("track <dir> <hours> <name> <audio[:rttm]>...")
        }
        let directory = URL(filePath: arguments[0], directoryHint: .isDirectory)
        let name = arguments[2]
        let inputs = arguments.dropFirst(3).map { argument in
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            return (audio: parts[0], rttm: parts.count > 1 ? parts[1] : nil)
        }
        let rate = VoiceCore.sampleRate
        let total = Int(hours * 3600 * rate)
        let base = mach_absolute_time()
        // A second track goes to a folder of its own first, then joins the recording.
        let joins = FileManager.default.fileExists(atPath: directory.appending(path: "meta.json").path)
        let target = joins ? directory.appending(path: ".\(name)-new", directoryHint: .isDirectory) : directory
        let store = try RecordingStore(directory: target, startHostTime: base, format: .adts)
        let writer = SegmentWriter(track: name, store: store, format: .adts, segmentSeconds: 300)
        var written = 0
        var rttm: [String] = []
        var used: [String] = []
        var pass = 0
        let started = ContinuousClock.now
        while written < total {
            pass += 1
            for input in inputs where written < total {
                let samples = try Engines.samples(input.audio)
                let take = min(samples.count / block * block, total - written)
                let offset = Double(written) / rate
                samples.withUnsafeBufferPointer { all in
                    for start in stride(from: 0, to: take, by: block) {
                        let host = base + ticks(Double(written + start) / rate)
                        writer.receive(UnsafeBufferPointer(rebasing: all[start..<(start + block)]), hostTime: host)
                    }
                }
                if let error = writer.error { throw ProbeError.message(error) }
                if let path = input.rttm {
                    rttm += try RTTM.read(path).filter { $0.start < Double(take) / rate }.map {
                        RTTM.Turn(speaker: $0.speaker, start: $0.start + offset,
                                  end: min($0.end, Double(take) / rate) + offset)
                    }.map(\.line)
                }
                used.append("\(URL(filePath: input.audio).lastPathComponent) \(String(format: "%.1f", Double(take) / rate)) s")
                written += take
            }
        }
        writer.finish()
        store.setState(.stopped)
        if joins { try join(target, into: directory) }
        if !rttm.isEmpty {
            try (rttm.joined(separator: "\n") + "\n").write(to: directory.appending(path: "\(name).rttm"),
                                                         atomically: true, encoding: .utf8)
        }
        let lead = try measureLead(directory: directory, track: name, source: inputs[0].audio, at: 0)
        let seeked = try measureLead(directory: directory, track: name, source: inputs[0].audio, at: 150)
        print("track \(name): \(String(format: "%.2f", Double(written) / rate / 3600)) h, \(writer.segmentCount) segments, passes \(pass), written in \(ContinuousClock.now - started)")
        print("decoder lead: \(lead) samples at the start, \(seeked) after a seek to 150 s (first segment against its source)")
        for line in used { print("  \(line)") }
    }

    /// Moves a track's segments into a recording and adds them to its `meta.json`.
    static func join(_ folder: URL, into directory: URL) throws {
        let manager = FileManager.default
        var meta = try RecordingReader.meta(directory)
        let added = try RecordingReader.meta(folder)
        for segment in added.segments {
            try manager.moveItem(at: folder.appending(path: segment.file), to: directory.appending(path: segment.file))
            meta.segments.append(segment)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: directory.appending(path: "meta.json"), options: .atomic)
        try manager.removeItem(at: folder)
    }

    static func ticks(_ seconds: Double) -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return UInt64((seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
    }

    /// How many samples AVAudioFile puts before the audio of an ADTS segment
    /// (AAC priming that the container does not mark): the lag of the best
    /// match of the decoded start against the source.
    static func measureLead(directory: URL, track: String, source: String, at seconds: Int) throws -> Int {
        let meta = try RecordingReader.meta(directory)
        guard let first = meta.segments.first(where: { $0.track == track }) else { return 0 }
        let from = seconds * 16_000
        let decoded = try RecordingReader.decode(directory.appending(path: first.file), from: from, count: 16_000 * 6)
        let original = Array(try Engines.samples(source).dropFirst(from).prefix(16_000 * 5))
        var best = (lag: 0, score: -Double.infinity)
        for lag in 0..<4_096 where lag + original.count <= decoded.count {
            var sum = 0.0
            for i in stride(from: 0, to: original.count, by: 4) {
                sum += Double(original[i] * decoded[i + lag])
            }
            if sum > best.score { best = (lag, sum) }
        }
        return best.lag
    }
}

/// A track of a recording on its own time: segments at their `startOffset`,
/// zeros in the gaps, each segment without the decoder's lead and cut to the
/// frames written. Reads only what is asked: four hours never sit in memory.
final class RecordingReader: AudioSampleSource, @unchecked Sendable {
    struct Piece {
        var url: URL
        var start: Int  // samples on the track's time
        var frames: Int
    }

    let pieces: [Piece]
    let lead: Int
    let sampleCount: Int
    private let lock = NSLock()
    private var open: (url: URL, file: AVAudioFile)?

    /// `lead`: samples the decoder adds before each segment (`track` measures it).
    init(directory: URL, track: String, lead: Int) throws {
        let meta = try Self.meta(directory)
        let rate = meta.sampleRate
        pieces = meta.segments.filter { $0.track == track }.map {
            Piece(url: directory.appending(path: $0.file), start: Int(($0.startOffset * rate).rounded()),
                  frames: Int($0.frames))
        }
        guard let last = pieces.last else { throw ProbeError.message("no segments of \(track)") }
        self.lead = lead
        sampleCount = last.start + last.frames
    }

    static func meta(_ directory: URL) throws -> RecordingMeta {
        try JSONDecoder().decode(RecordingMeta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
    }

    func read(_ range: Range<Int>) throws -> [Float] {
        var out = [Float](repeating: 0, count: range.count)
        try out.withUnsafeMutableBufferPointer {
            try copySamples(into: $0.baseAddress!, offset: range.lowerBound, count: range.count)
        }
        return out
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        destination.initialize(repeating: 0, count: count)
        let end = offset + count
        for piece in pieces where piece.start < end && piece.start + piece.frames > offset {
            let from = max(offset, piece.start), to = min(end, piece.start + piece.frames)
            let samples = try lock.withLock {
                try decode(piece.url, from: lead + from - piece.start, count: to - from)
            }
            samples.withUnsafeBufferPointer {
                (destination + (from - offset)).update(from: $0.baseAddress!, count: min($0.count, to - from))
            }
        }
    }

    private func decode(_ url: URL, from frame: Int, count: Int) throws -> [Float] {
        if open?.url != url {
            open = (url, try AVAudioFile(forReading: url))
        }
        let file = open!.file
        return try Self.read(file, from: frame, count: count)
    }

    static func decode(_ url: URL, from frame: Int, count: Int) throws -> [Float] {
        try read(try AVAudioFile(forReading: url), from: frame, count: count)
    }

    private static func read(_ file: AVAudioFile, from frame: Int, count: Int) throws -> [Float] {
        file.framePosition = AVAudioFramePosition(frame)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

/// Speaker turns in RTTM: `SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>`.
enum RTTM {
    struct Turn {
        var speaker: String
        var start: Double
        var end: Double

        var line: String {
            String(format: "SPEAKER track 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>", start, end - start, speaker)
        }
    }

    static func read(_ path: String) throws -> [Turn] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let duration = Double(f[4]) else {
                return nil
            }
            return Turn(speaker: String(f[7]), start: start, end: start + duration)
        }
    }
}

/// Where a window ends: in the quietest stretch of its last `search`
/// seconds by Silero VAD, so a cut falls between words.
enum WindowCut {
    /// `probabilities`: one per `VoiceActivity.chunk` from `tailStart`.
    /// Returns the sample (from the window's start) to cut at: the middle of
    /// the longest run below the threshold, or of the quietest chunk.
    static func cut(probabilities: [Float], tailStart: Int, threshold: Float = VoiceActivity.threshold) -> Int {
        let chunk = VoiceActivity.chunk
        guard !probabilities.isEmpty else { return tailStart }
        var best = (start: 0, length: 0)
        var run = (start: 0, length: 0)
        for (i, p) in probabilities.enumerated() {
            if p < threshold {
                run = run.length == 0 ? (i, 1) : (run.start, run.length + 1)
                // `>=`: a later run of the same length keeps more of the window.
                if run.length >= best.length { best = run }
            } else {
                run = (0, 0)
            }
        }
        if best.length > 0 {
            return tailStart + (best.start * chunk) + best.length * chunk / 2
        }
        let quietest = probabilities.indices.min { probabilities[$0] < probabilities[$1] }!
        return tailStart + quietest * chunk + chunk / 2
    }
}

struct TimedPiece {
    var start: Double
    var end: Double
    var text: String
}

/// A long-audio engine: one window in, its pieces with times from the window's start.
protocol WindowEngine: AnyObject {
    var name: String { get }
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> [TimedPiece]
    func unload() async
}

/// Parakeet: words from the token timings.
/// `@unchecked`: the manager is an actor; the rest is set once at load.
final class ParakeetWindows: WindowEngine, @unchecked Sendable {
    let name: String
    private let folder: URL
    private var manager: AsrManager?

    init(folder: URL, name: String = "parakeet-tdt-v3") {
        self.folder = folder
        self.name = name
    }

    func load() async throws {
        let models = try AsrModels.loadLocal(from: folder, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> [TimedPiece] {
        guard let manager else { throw ProbeError.message("not loaded") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedPiece(start: $0.startTime, end: $0.endTime, text: $0.word)
        }
    }

    /// Text only, as dictation asks for it.
    func text(_ samples: [Float]) async throws -> String {
        guard let manager else { throw ProbeError.message("not loaded") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// Whisper: segments with timestamps.
final class WhisperWindows: WindowEngine {
    let name = "whisper-large-v3-turbo-632mb"
    private let engine: WhisperEngine

    init(folder: URL) { engine = WhisperEngine(directory: folder) }

    func load() async throws { try await engine.load() }

    func transcribe(_ samples: [Float]) async throws -> [TimedPiece] {
        try await engine.timedSegments(samples).map { TimedPiece(start: $0.start, end: $0.end, text: $0.text) }
    }

    func unload() async { await engine.unload() }
}

/// `longform <model> <recording> [options]`: a recording's tracks, one after
/// the other, in windows of up to `--window` seconds cut at silence, with
/// `--overlap` seconds shared between windows. Between windows the loop
/// yields to dictation. Writes `<track>.<model>.tsv` and prints JSON.
///
/// `--dictation none|yield|parallel`, `--every <s>`: a dictation of the
/// phrase `--phrase` every `<s>` seconds of the run, on its own Parakeet.
/// `yield` makes it wait for the window in work, `parallel` runs it at once.
enum LongformCommand {
    struct Options {
        var model = "parakeet-tdt-v3"
        var recording = URL(filePath: ".")
        var tracks = ["mic", "sys"]
        var window = 300.0
        var overlap = 2.0
        var search = 30.0
        var lead = 0
        var dictation = "none"
        var every = 40.0
        var phrase: String?
        var limit: Double?
    }

    struct Dictation {
        var requested: Double
        var started: Double
        var finished: Double
        var text: String
    }

    static func run(_ arguments: [String]) async throws {
        var options = Options()
        var rest = arguments[...]
        guard let model = rest.popFirst(), let recording = rest.popFirst() else {
            throw ProbeError.message("longform <model> <recording> [--tracks mic,sys] [--window s] [--overlap s] [--lead n] [--dictation none|yield|parallel --every s --phrase wav] [--limit s]")
        }
        options.model = model
        options.recording = URL(filePath: recording, directoryHint: .isDirectory)
        while let flag = rest.popFirst() {
            let value = rest.popFirst() ?? ""
            switch flag {
            case "--tracks": options.tracks = value.split(separator: ",").map(String.init)
            case "--window": options.window = Double(value) ?? options.window
            case "--overlap": options.overlap = Double(value) ?? options.overlap
            case "--search": options.search = Double(value) ?? options.search
            case "--lead": options.lead = Int(value) ?? 0
            case "--dictation": options.dictation = value
            case "--every": options.every = Double(value) ?? options.every
            case "--phrase": options.phrase = value
            case "--limit": options.limit = Double(value)
            default: throw ProbeError.message("unknown flag \(flag)")
            }
        }
        try await run(options)
    }

    static func run(_ options: Options) async throws {
        let store = ProbeStore.make()
        let rate = VoiceCore.sampleRate
        guard let folder = await store.folder(of: options.model) else { throw ProbeError.message("\(options.model) is not ready") }
        let vad = SileroVAD(store: store)
        let engine: WindowEngine = options.model.hasPrefix("whisper") ? WhisperWindows(folder: folder)
            : ParakeetWindows(folder: folder, name: options.model)

        let baseline = MemorySnapshot.now()
        let meter = RunMeter()
        var loads: [String: Double] = [:]
        loads["engine"] = try await seconds { try await engine.load() }
        loads["vad"] = try await seconds { try await vad.prepare() }

        // Dictation's own engine and phrase, with its idle time first.
        var dictator: ParakeetWindows?
        var phrase: [Float] = []
        var idle: [Double] = []
        if options.dictation != "none" {
            guard let path = options.phrase, let parakeet = await store.folder(of: "parakeet-tdt-v3") else {
                throw ProbeError.message("--dictation needs --phrase and parakeet-tdt-v3")
            }
            phrase = try Engines.samples(path)
            let own = ParakeetWindows(folder: parakeet)
            loads["dictation"] = try await seconds { try await own.load() }
            for _ in 0..<3 { idle.append(try await seconds { _ = try await own.text(phrase) }) }
            dictator = own
        }
        let loaded = MemorySnapshot.now()
        let runMeter = RunMeter()

        let clock = ContinuousClock.now
        func now() -> Double {
            let elapsed = ContinuousClock.now - clock
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        let requests = RequestQueue()
        var dictations: [Dictation] = []
        let parallel = ParallelDictations()
        let spoken = phrase, dictation = dictator
        let ticker: Task<Void, Never>? = options.dictation == "none" ? nil : Task {
            var next = options.every
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(0, next - now())))
                if Task.isCancelled { break }
                let at = now()
                if options.dictation == "parallel", let dictation {
                    let text = (try? await dictation.text(spoken)) ?? "<error>"
                    parallel.append(Dictation(requested: at, started: at, finished: now(), text: text))
                } else {
                    requests.push(at)
                }
                next += options.every
            }
        }

        var tracks: [[String: Any]] = []
        for track in options.tracks {
            let reader = try RecordingReader(directory: options.recording, track: track, lead: options.lead)
            let total = options.limit.map { min(reader.sampleCount, Int($0 * rate)) } ?? reader.sampleCount
            let window = Int(options.window * rate), overlap = Int(options.overlap * rate)
            let search = Int(options.search * rate)
            var position = 0
            var pieces: [TimedPiece] = []
            var keepFrom = 0.0
            var windows: [[String: Double]] = []
            var vadTime = 0.0, readTime = 0.0
            let trackStart = now()
            while position < total {
                // The yield point: dictation that asked meanwhile goes first.
                while let asked = requests.pop(), let dictator {
                    let started = now()
                    let text = try await dictator.text(phrase)
                    dictations.append(Dictation(requested: asked, started: started, finished: now(), text: text))
                }
                let end = min(position + window, total)
                var samples: [Float] = []
                readTime += try await seconds { samples = try reader.read(position..<end) }
                var cut = end
                if end < total {
                    let tailStart = max(0, samples.count - search)
                    var probabilities: [Float] = []
                    vadTime += try await seconds {
                        probabilities = try await vad.speechProbabilities(Array(samples[tailStart...]))
                    }
                    cut = position + WindowCut.cut(probabilities: probabilities, tailStart: tailStart)
                }
                let offset = Double(position) / rate
                let boundary = end < total ? Double(cut) / rate - options.overlap / 2 : .infinity
                var found: [TimedPiece] = []
                let time = try await seconds { found = try await engine.transcribe(Array(samples[0..<(cut - position)])) }
                for piece in found {
                    let shifted = TimedPiece(start: piece.start + offset, end: piece.end + offset, text: piece.text)
                    if shifted.start >= keepFrom && shifted.start < boundary { pieces.append(shifted) }
                }
                windows.append(["start": offset, "audio_s": Double(cut - position) / rate, "transcribe_s": time])
                FileHandle.standardError.write(Data(String(format: "%@ %@ %.0f/%.0f s: %.2f s, %d pieces\n",
                    track, engine.name, Double(cut) / rate, Double(total) / rate, time, found.count).utf8))
                keepFrom = boundary
                position = end < total ? cut - overlap : end
            }
            let wall = now() - trackStart
            let out = options.recording.appending(path: "\(track).\(engine.name).tsv")
            try pieces.map { String(format: "%.2f\t%.2f\t%@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
                .write(to: out, atomically: true, encoding: .utf8)
            let times = windows.compactMap { $0["transcribe_s"] }.sorted()
            tracks.append([
                "track": track, "audio_h": Double(total) / rate / 3600, "wall_s": wall,
                "rtfx": Double(total) / rate / wall, "windows": windows.count,
                "window_s_median": times[times.count / 2], "window_s_max": times.last ?? 0,
                "vad_s": vadTime, "read_s": readTime, "pieces": pieces.count, "out": out.lastPathComponent,
            ])
        }
        ticker?.cancel()
        let report = runMeter.stop()
        let whole = meter.stop()
        await engine.unload()
        await vad.unload()
        await dictator?.unload()

        let all = dictations + parallel.all
        func waits(_ list: [Dictation]) -> [String: Double] {
            let wait = list.map { $0.started - $0.requested }.sorted()
            let total = list.map { $0.finished - $0.requested }.sorted()
            guard !wait.isEmpty else { return [:] }
            return ["count": Double(list.count), "wait_median_s": wait[wait.count / 2], "wait_max_s": wait.last!,
                    "total_median_s": total[total.count / 2], "total_max_s": total.last!]
        }
        var json: [String: Any] = [
            "model": engine.name, "window_s": options.window, "overlap_s": options.overlap,
            "dictation": options.dictation, "load_s": loads, "tracks": tracks,
            "rss_baseline_mb": baseline.rssMB, "rss_loaded_mb": loaded.rssMB, "footprint_loaded_mb": loaded.footprintMB,
            "run": report.json, "with_load": whole.json,
        ]
        if !all.isEmpty {
            json["dictation_idle_s"] = idle.sorted()[idle.count / 2]
            json["dictations"] = waits(all)
            json["dictation_texts"] = Array(Set(all.map(\.text))).prefix(3).map { $0 }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}

/// Dictation requests waiting for the next yield point.
final class RequestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []

    func push(_ time: Double) { lock.withLock { times.append(time) } }

    func pop() -> Double? { lock.withLock { times.isEmpty ? nil : times.removeFirst() } }
}

final class ParallelDictations: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [LongformCommand.Dictation] = []

    func append(_ dictation: LongformCommand.Dictation) { lock.withLock { list.append(dictation) } }

    var all: [LongformCommand.Dictation] { lock.withLock { list } }
}

/// The app's model store over `PEREKEY_VOICE_MODELS`.
enum ProbeStore {
    static func make() -> VoiceModelStore {
        let root = ProcessInfo.processInfo.environment["PEREKEY_VOICE_MODELS"]
            ?? FileManager.default.currentDirectoryPath + "/models"
        let models = URL(filePath: root, directoryHint: .isDirectory)
        return VoiceModelStore(
            locations: VoiceModelLocations(models: models, managed: models.appending(path: "../managed").standardized,
                                           coreMLCache: models.appending(path: "../coreml-cache").standardized),
            managed: ManagedSettings())
    }
}
