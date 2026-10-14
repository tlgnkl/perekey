// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import FluidAudio
import Foundation
import PerekeyVoiceCore

/// «Разделить по спикерам»: FluidAudio's offline pipeline (pyannote
/// community-1 segmentation, WeSpeaker embeddings, VBx clustering). Stage 0
/// chose it over the other five: the fewest speakers confused (2 %), the
/// right number of them every time, and the only one that reads audio from
/// disk, which keeps an hour at 0.4 GB. Its models are CC-BY-4.0 (NOTICE of
/// FluidInference/speaker-diarization-coreml) and come from the store, never
/// from FluidAudio's loaders.
public actor VBxDiarizer: DiarizerEngine {
    public static let modelID = "diarizer-offline-vbx"
    public nonisolated let id = VBxDiarizer.modelID
    private let store: VoiceModelStore
    private let opener: any LongAudioOpener
    private var manager: OfflineDiarizerManager?

    public init(store: VoiceModelStore, opener: any LongAudioOpener = VoiceAudioOpener()) {
        self.store = store
        self.opener = opener
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        _ = VoiceEngines.offline
        let folder = try await store.acquire(Self.modelID)
        do {
            let manager = OfflineDiarizerManager(config: .default)
            manager.initialize(models: try Self.models(in: folder))
            self.manager = manager
        } catch {
            await store.release(Self.modelID)
            throw error
        }
    }

    public func unload() async {
        guard manager != nil else { return }
        manager = nil
        await store.release(Self.modelID)
    }

    public func diarize(_ source: PerekeyVoiceCore.AudioSource, progress: @escaping @Sendable (Double) -> Void)
        async throws -> [SpeakerTurn]
    {
        // The manager is not Sendable; this actor is its only user, and one
        // diarization runs at a time.
        guard let found = manager else { throw SpeechEngineError.notPrepared }
        nonisolated(unsafe) let manager = found
        let audio = try await opener.open(source)
        defer { audio.close() }
        guard let samples = audio as? any AudioSampleSource else { throw LongAudioError.unreadable }
        let result = try await manager.process(audioSource: samples, audioLoadingSeconds: 0) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
        // FluidAudio names the clusters; numbers in order of first appearance.
        var clusters: [String: Int] = [:]
        return result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }.map { segment in
            let cluster = clusters[segment.speakerId] ?? clusters.count
            clusters[segment.speakerId] = cluster
            return SpeakerTurn(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds),
                               speaker: cluster)
        }
    }

    /// The four models and the PLDA ψ, as `OfflineDiarizerModels.load` takes
    /// them without ModelHub: FBank on the CPU, the rest on all units.
    static func models(in folder: URL) throws -> OfflineDiarizerModels {
        let start = Date()
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: folder.appending(path: name, directoryHint: .isDirectory),
                               configuration: configuration)
        }
        return OfflineDiarizerModels(
            segmentationModel: try model("Segmentation.mlmodelc", .all),
            fbankModel: try model("FBank.mlmodelc", .cpuOnly),
            embeddingModel: try model("Embedding.mlmodelc", .all),
            pldaRhoModel: try model("PldaRho.mlmodelc", .all),
            pldaPsi: try psi(Data(contentsOf: folder.appending(path: "plda-parameters.json"))),
            compilationDuration: Date().timeIntervalSince(start))
    }

    enum ModelError: Error, Equatable {
        case noPsi
    }

    /// `tensors.psi.data_base64` of `plda-parameters.json`: little-endian floats.
    static func psi(_ json: Data) throws -> [Double] {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tensors = object["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String,
              let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !bytes.isEmpty
        else { throw ModelError.noPsi }
        var floats = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        return floats.map(Double.init)
    }
}
