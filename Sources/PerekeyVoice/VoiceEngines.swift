// SPDX-License-Identifier: GPL-3.0-or-later

@preconcurrency import CoreML
import FluidAudio
import Foundation
import PerekeyVoiceCore
import WhisperKit

/// The speech engines of the catalog's recognizers. Each holds its model in
/// `VoiceModelStore` from `prepare` to `unload`, so the store neither
/// deletes nor replaces it in use. Models come only from the store: the
/// engines call none of the loaders of FluidAudio or WhisperKit, and
/// FluidAudio is kept offline (scripts/check-voice-loaders.sh).
public enum VoiceEngines {
    /// The engine for a recognizer of the catalog; nil for other models.
    public static func make(model id: String, store: VoiceModelStore) -> (any SpeechEngine)? {
        switch ModelCatalog.entry(id: id)?.engine {
        case .fluidAudioAsr: FluidAudioEngine(id: id, store: store)
        case .whisperKit: WhisperKitEngine(id: id, store: store)
        case .fluidAudioVad, .fluidAudioDiarizer, nil: nil
        }
    }

    /// Without it, a FluidAudio model that fails to load is deleted and
    /// downloaded again from its hub. Set once, before any FluidAudio call.
    static let offline: Void = { ModelHub.offlineMode = true }()
}

/// Parakeet TDT through FluidAudio, from the model's folder.
public actor FluidAudioEngine: SpeechEngine {
    public nonisolated let id: String
    private let store: VoiceModelStore
    private var manager: AsrManager?

    public init(id: String = "parakeet-tdt-v3", store: VoiceModelStore) {
        self.id = id
        self.store = store
    }

    private var version: AsrModelVersion { id == "parakeet-ultra" ? .ultra : .v3 }

    public func prepare() async throws {
        guard manager == nil else { return }
        _ = VoiceEngines.offline
        let folder = try await store.acquire(id)
        do {
            let models = try AsrModels.loadLocal(from: folder, version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.manager = manager
        } catch {
            await store.release(id)
            throw error
        }
    }

    public func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        guard let manager else { throw SpeechEngineError.notPrepared }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio.samples, decoderState: &state)
        return Transcript(text: result.text)
    }

    public func unload() async {
        guard let manager else { return }
        self.manager = nil
        await manager.cleanup()
        await store.release(id)
    }
}

/// Whisper through WhisperKit, from the model's folder; the tokenizer lies
/// in its `tokenizer/` (`ModelCatalog`) and loads from there only
/// (`StoreWhisperKit`). The language is detected.
public actor WhisperKitEngine: SpeechEngine {
    public nonisolated let id: String
    public nonisolated var addsSignOffs: Bool { true }
    private let store: VoiceModelStore
    private var kit: StoreWhisperKit?

    public init(id: String = "whisper-large-v3-turbo-632mb", store: VoiceModelStore) {
        self.id = id
        self.store = store
    }

    public func prepare() async throws {
        guard kit == nil else { return }
        let folder = try await store.acquire(id)
        do {
            kit = try await Self.load(from: folder)
        } catch {
            await store.release(id)
            throw error
        }
    }

    /// The tokenizer first, once: a broken one stops the load before CoreML.
    static func load(from folder: URL) async throws -> StoreWhisperKit {
        let tokenizer = try await LocalWhisperTokenizer(
            folder: folder.appending(path: "tokenizer", directoryHint: .isDirectory))
        let config = WhisperKitConfig(
            modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: false, load: false, download: false)
        let kit = try await StoreWhisperKit(config, tokenizer: tokenizer)
        try await kit.loadModels()
        return kit
    }

    public func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        guard let kit else { throw SpeechEngineError.notPrepared }
        let options = DecodingOptions(
            task: .transcribe, language: nil, detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: audio.samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func unload() async {
        guard let kit else { return }
        self.kit = nil
        await kit.unloadModels()
        await store.release(id)
    }
}

/// Silero VAD through FluidAudio, the CoreML model from the store's folder.
public actor SileroVAD: SpeechDetector {
    public static let modelID = "silero-vad"
    private let store: VoiceModelStore
    private var manager: VadManager?

    public init(store: VoiceModelStore) {
        self.store = store
    }

    /// The `.mlmodelc` folder the catalog lists for the model.
    static var modelPath: String? {
        ModelCatalog.entry(id: modelID)?.sources.first?.files.first?.path
            .split(separator: "/").first.map(String.init)
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        _ = VoiceEngines.offline
        guard let path = Self.modelPath else { throw VoiceModelFailure.unknownModel(Self.modelID) }
        let folder = try await store.acquire(Self.modelID)
        do {
            let config = VadConfig.default
            let configuration = MLModelConfiguration()
            configuration.computeUnits = config.computeUnits
            let model = try MLModel(contentsOf: folder.appending(path: path, directoryHint: .isDirectory),
                                    configuration: configuration)
            manager = VadManager(config: config, vadModel: model)
        } catch {
            await store.release(Self.modelID)
            throw error
        }
    }

    public func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        guard let manager else { throw SpeechEngineError.notPrepared }
        return try await manager.process(samples).map(\.probability)
    }

    public func unload() async {
        guard manager != nil else { return }
        manager = nil
        await store.release(Self.modelID)
    }
}
