// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import FluidAudio
import Foundation

/// `diarize <method> <audio | recording> [options]`: one diarizer of
/// FluidAudio 0.17.7 over a file or a recording's track, with time, memory
/// and, given a reference RTTM, the DER (collar 0 and 0.25 s). Every model
/// loads from a local folder: the store's for the catalog's diarizers,
/// `PEREKEY_PROBE_EXTRA` for LS-EEND and Nemotron 3, which the catalog has not.
///
/// Methods: `vbx` (offline pyannote + VBx), `pyannote` (`DiarizerManager`,
/// pyannote + WeSpeaker), `sortformer` (offline Sortformer v2.1, up to 4
/// speakers), `lseend-dih3`, `lseend-ami` (LS-EEND), `nemotron3` (offline preset).
enum DiarizeCommand {
    static let methods = ["vbx", "pyannote", "sortformer", "lseend-dih3", "lseend-ami", "nemotron3"]

    static func run(_ arguments: [String]) async throws {
        var rest = arguments[...]
        guard let method = rest.popFirst(), methods.contains(method), let input = rest.popFirst() else {
            throw ProbeError.message("diarize \(methods.joined(separator: "|")) <audio|recording> [--track sys] [--lead n] [--rttm ref] [--limit s] [--out hyp.rttm] [--stream]")
        }
        var track = "sys", lead = 0, reference: String?, limit: Double?, output: String?, stream = false
        while let flag = rest.popFirst() {
            if flag == "--stream" {
                stream = true
                continue
            }
            let value = rest.popFirst() ?? ""
            switch flag {
            case "--track": track = value
            case "--lead": lead = Int(value) ?? 0
            case "--rttm": reference = value
            case "--limit": limit = Double(value)
            case "--out": output = value
            default: throw ProbeError.message("unknown flag \(flag)")
            }
        }
        let rate = 16_000.0
        let baseline = MemorySnapshot.now()
        let meter = RunMeter()

        // The audio: a recording's track from its segments, or a file.
        var audioSeconds = 0.0
        var samples: [Float] = []
        var source: RecordingReader?
        let readTime = try await seconds {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory), isDirectory.boolValue {
                let reader = try RecordingReader(directory: URL(filePath: input, directoryHint: .isDirectory),
                                                 track: track, lead: lead)
                let count = limit.map { min(reader.sampleCount, Int($0 * rate)) } ?? reader.sampleCount
                // `--stream`: VBx reads the segments as it goes, the track never sits in memory.
                if stream, method == "vbx", limit == nil {
                    source = reader
                } else {
                    samples = try reader.read(0..<count)
                }
                audioSeconds = Double(count) / rate
            } else {
                samples = try Engines.samples(input)
                if let limit { samples = Array(samples.prefix(Int(limit * rate))) }
            }
            if source == nil { audioSeconds = Double(samples.count) / rate }
        }
        let audioLoaded = MemorySnapshot.now()

        var turns: [RTTM.Turn] = []
        var load = 0.0
        var process = 0.0
        switch method {
        case "vbx":
            let manager = OfflineDiarizerManager(config: .default)
            load = try await seconds { manager.initialize(models: try await vbxModels()) }
            var result: DiarizationResult?
            process = try await seconds {
                result = if let source {
                    try await manager.process(audioSource: source, audioLoadingSeconds: 0)
                } else {
                    try await manager.process(audio: samples)
                }
            }
            turns = result!.segments.map { .init(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        case "pyannote":
            let folder = try await storeFolder("diarizer-pyannote")
            let manager = DiarizerManager(config: .default)
            load = try await seconds {
                manager.initialize(models: try DiarizerModels.load(
                    localSegmentationModel: folder.appending(path: "pyannote_segmentation.mlmodelc"),
                    localEmbeddingModel: folder.appending(path: "wespeaker_v2.mlmodelc")))
            }
            var result: DiarizationResult?
            process = try await seconds { result = try manager.performCompleteDiarization(samples) }
            turns = result!.segments.map { .init(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        case "sortformer":
            let folder = try await storeFolder("diarizer-sortformer")
            let diarizer = OfflineSortformerDiarizer()
            load = try await seconds {
                try await diarizer.initialize(modelPath: folder.appending(path: "v3/fp16/SortformerOffline_v2.1.mlmodelc"))
            }
            var timeline: DiarizerTimeline?
            process = try await seconds { timeline = try diarizer.processComplete(samples, sourceSampleRate: rate) }
            turns = Self.turns(timeline!)
        case "lseend-dih3", "lseend-ami":
            let variant = method == "lseend-ami" ? "ami" : "dih3"
            let url = try extra().appending(path: "lseend/\(variant)/ls_eend_\(variant)_100ms.mlmodelc")
            var diarizer: LSEENDDiarizer?
            load = try await seconds { diarizer = try LSEENDDiarizer(model: try LSEENDModel(modelURL: url)) }
            var timeline: DiarizerTimeline?
            process = try await seconds { timeline = try diarizer!.processComplete(samples, sourceSampleRate: rate) }
            turns = Self.turns(timeline!)
        case "nemotron3":
            let directory = try extra().appending(path: "nemotron3", directoryHint: .isDirectory)
            var diarizer: Nemotron3Diarizer?
            load = try await seconds {
                diarizer = Nemotron3Diarizer(config: .offline,
                                             models: try await Nemotron3Models.load(config: .offline, directory: directory))
            }
            var output: (probabilities: [Float], frameCount: Int)?
            process = try await seconds { output = try diarizer!.processComplete(samples) }
            turns = Nemotron3Diarizer.segments(probabilities: output!.probabilities, frameCount: output!.frameCount)
                .map { .init(speaker: "S\($0.speakerIndex)", start: Double($0.startSeconds), end: Double($0.endSeconds)) }
        default:
            throw ProbeError.message("unknown method \(method)")
        }
        let report = meter.stop()

        if let output {
            try (turns.map(\.line).joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        }
        var json: [String: Any] = [
            "method": method, "input": URL(filePath: input).lastPathComponent, "audio_s": audioSeconds,
            "read_s": readTime, "load_s": load, "process_s": process, "rtfx": audioSeconds / max(process, 1e-9),
            "speakers_found": Set(turns.map(\.speaker)).count, "turns": turns.count,
            "rss_baseline_mb": baseline.rssMB, "rss_audio_mb": audioLoaded.rssMB, "run": report.json,
        ]
        if let reference {
            let ref = try RTTM.read(reference).filter { $0.start < audioSeconds }
                .map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: min($0.end, audioSeconds)) }
            let hyp = turns.map { DERSpeakerSegment(speaker: $0.speaker, start: $0.start, end: $0.end) }
            json["speakers_ref"] = Set(ref.map(\.speaker)).count
            for collar in [0.0, 0.25] {
                let der = DiarizationDER.compute(ref: ref, hyp: hyp, frameStep: 0.01, collar: collar)
                json["der_collar_\(collar)"] = [
                    "der": der.der, "miss": der.miss, "false_alarm": der.falseAlarm, "confusion": der.confusion,
                    "ref_speech_s": der.totalRefSpeech,
                ]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }

    static func turns(_ timeline: DiarizerTimeline) -> [RTTM.Turn] {
        timeline.speakers.values.flatMap { speaker in
            (speaker.finalizedSegments + speaker.tentativeSegments).map {
                RTTM.Turn(speaker: "S\(speaker.index)", start: Double($0.startTime), end: Double($0.endTime))
            }
        }.sorted { $0.start < $1.start }
    }

    static func storeFolder(_ id: String) async throws -> URL {
        guard let folder = await ProbeStore.make().folder(of: id) else { throw ProbeError.message("\(id) is not ready") }
        return folder
    }

    static func extra() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PEREKEY_PROBE_EXTRA"] else {
            throw ProbeError.message("set PEREKEY_PROBE_EXTRA to the folder with lseend/ and nemotron3/")
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The offline pipeline's four models and the PLDA ψ, as
    /// `OfflineDiarizerModels.load` takes them, without ModelHub: FBank on
    /// the CPU, the rest on all units.
    static func vbxModels() async throws -> OfflineDiarizerModels {
        let folder = try await storeFolder("diarizer-offline-vbx")
        let start = Date()
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appending(path: name), configuration: configuration)
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "plda-parameters.json")))
        guard let tensors = (json as? [String: Any])?["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any], let base64 = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        else { throw ProbeError.message("plda-parameters.json: no psi") }
        var floats = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return OfflineDiarizerModels(
            segmentationModel: try model("Segmentation.mlmodelc", .all), fbankModel: try model("FBank.mlmodelc", .cpuOnly),
            embeddingModel: try model("Embedding.mlmodelc", .all), pldaRhoModel: try model("PldaRho.mlmodelc", .all),
            pldaPsi: floats.map(Double.init), compilationDuration: Date().timeIntervalSince(start))
    }
}
