// SPDX-License-Identifier: GPL-3.0-or-later

import FluidAudio
import Foundation
import WhisperKit

struct MemorySnapshot {
    let rssMB: Double
    let footprintMB: Double

    static func now() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemorySnapshot(rssMB: -1, footprintMB: -1) }
        return MemorySnapshot(
            rssMB: Double(info.resident_size) / 1_048_576, footprintMB: Double(info.phys_footprint) / 1_048_576)
    }
}

protocol ProbeEngine: AnyObject {
    func load() async throws
    func transcribe(_ samples: [Float], language: String?) async throws -> String
    func unload() async
}

/// Parakeet through `AsrModels.loadLocal`: no ModelHub, no download path.
final class ParakeetEngine: ProbeEngine {
    private let directory: URL
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(directory: URL, version: AsrModelVersion) {
        self.directory = directory
        self.version = version
    }

    func load() async throws {
        let models = try AsrModels.loadLocal(from: directory, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let manager else { throw ProbeError.message("not loaded") }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &state).text
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}

/// WhisperKit from a local folder; the tokenizer sits in `tokenizer/`.
final class WhisperEngine: ProbeEngine {
    private let directory: URL
    private var kit: WhisperKit?

    init(directory: URL) { self.directory = directory }

    func load() async throws {
        let config = WhisperKitConfig(
            modelFolder: directory.path,
            tokenizerFolder: directory.appendingPathComponent("tokenizer"),
            verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        kit = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard let kit else { throw ProbeError.message("not loaded") }
        let options = DecodingOptions(
            task: .transcribe, language: language, detectLanguage: language == nil, skipSpecialTokens: true,
            withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

enum Engines {
    static func make(_ id: String) throws -> ProbeEngine {
        let directory = ProbePaths.modelDirectory(id)
        switch id {
        case "parakeet-tdt-v3": return ParakeetEngine(directory: directory, version: .v3)
        case "parakeet-ultra": return ParakeetEngine(directory: directory, version: .ultra)
        case "whisper-large-v3-turbo-632mb": return WhisperEngine(directory: directory)
        default: throw ProbeError.message("no speech engine for \(id)")
        }
    }

    static func samples(_ path: String) throws -> [Float] {
        try AudioConverter().resampleAudioFile(path: path)
    }

    /// `ru.wav` → "ru", `mixed.wav` → nil (let the model decide).
    static func language(of path: String) -> String? {
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return ["ru", "en", "uk"].contains(name) ? name : nil
    }
}
