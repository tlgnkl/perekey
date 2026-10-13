// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import CryptoKit
import FluidAudio
import Foundation
import Speech

func seconds(_ block: () async throws -> Void) async rethrows -> Double {
    let start = ContinuousClock.now
    try await block()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
}

func format(_ value: Double) -> String { String(format: "%.2f", value) }

enum Commands {
    /// Prints the text each file gets from one engine.
    static func recognize(id: String, files: [String]) async throws {
        let engine = try Engines.make(id)
        try await engine.load()
        for file in files {
            let samples = try Engines.samples(file)
            var text = ""
            let time = try await seconds { text = try await engine.transcribe(samples, language: Engines.language(of: file)) }
            let name = URL(fileURLWithPath: file).lastPathComponent
            print("\(id)\t\(name)\t\(format(Double(samples.count) / 16000))s audio\t\(format(time))s\t\(text)")
        }
        await engine.unload()
    }

    /// One JSON line: load time, memory after load / transcription / unload.
    static func measure(id: String, file: String) async throws {
        let samples = try Engines.samples(file)
        let language = Engines.language(of: file)
        let before = MemorySnapshot.now()
        let engine = try Engines.make(id)
        let load = try await seconds { try await engine.load() }
        let loaded = MemorySnapshot.now()
        // The first transcription warms the graph; later runs show steady state.
        var text = ""
        let first = try await seconds { text = try await engine.transcribe(samples, language: language) }
        var runs: [Double] = []
        for _ in 0..<3 {
            runs.append(try await seconds { text = try await engine.transcribe(samples, language: language) })
        }
        let used = MemorySnapshot.now()
        await engine.unload()
        try await Task.sleep(for: .seconds(2))
        malloc_zone_pressure_relief(nil, 0)
        let unloaded = MemorySnapshot.now()
        let json: [String: Any] = [
            "id": id, "audio_s": Double(samples.count) / 16000, "load_s": load, "first_transcribe_s": first,
            "transcribe_s": runs.sorted()[1], "rss_before_mb": before.rssMB, "rss_loaded_mb": loaded.rssMB,
            "footprint_loaded_mb": loaded.footprintMB, "rss_used_mb": used.rssMB,
            "footprint_used_mb": used.footprintMB, "rss_unloaded_mb": unloaded.rssMB,
            "footprint_unloaded_mb": unloaded.footprintMB, "text": text,
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// Loads every `.mlmodelc` of a model with `MLModel(contentsOf:)`; for VAD it also runs a phrase.
    static func loadCheck(id: String, file: String?) async throws {
        let directory = ProbePaths.modelDirectory(id)
        let compiled = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "mlmodelc" }.sorted { $0.path < $1.path } ?? []
        let before = MemorySnapshot.now()
        var models: [(URL, MLModel)] = []
        for url in compiled {
            var model: MLModel?
            let time = try await seconds { model = try MLModel(contentsOf: url) }
            models.append((url, model!))
            print("\(id)\t\(url.lastPathComponent)\tload \(format(time))s")
        }
        let loaded = MemorySnapshot.now()
        print("\(id)\tmemory\trss \(format(before.rssMB)) -> \(format(loaded.rssMB)) MB\tfootprint \(format(before.footprintMB)) -> \(format(loaded.footprintMB)) MB")
        if id == "silero-vad", let file, let model = models.first?.1 {
            let vad = VadManager(config: .default, vadModel: model)
            let results = try await vad.process(try Engines.samples(file))
            let active = results.filter(\.isVoiceActive).count
            print("\(id)\tvad\t\(results.count) chunks of 4096 samples, \(active) voiced")
        }
    }

    /// Corrupts one `.mlmodelc` in a copy and loads it with `offlineMode` on.
    static func offlineCheck(scratch: String, online: Bool) async throws {
        if online { ModelHub.offlineMode = false }
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: scratch)
        try? fileManager.removeItem(at: root)
        let folder = "parakeet-tdt-0.6b-v3"  // `Repo.parakeetV3.folderName`
        let broken = root.appendingPathComponent("broken").appendingPathComponent(folder)
        let healthy = root.appendingPathComponent("healthy").appendingPathComponent(folder)
        for target in [broken, healthy] {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: ProbePaths.modelDirectory("parakeet-tdt-v3"), to: target)
        }
        let victim = broken.appendingPathComponent("Encoder.mlmodelc/coremldata.bin")
        let handle = try FileHandle(forWritingTo: victim)
        try handle.truncate(atOffset: 64)
        try handle.close()
        print("pid \(getpid()), offlineMode \(ModelHub.offlineMode), truncated \(victim.path) to 64 bytes")
        try await Task.sleep(for: .seconds(3))  // lets the sampler attach

        let digestBefore = try digest(of: broken)
        for (name, directory) in [("broken", broken), ("healthy", healthy)] {
            do {
                _ = try await AsrModels.load(from: directory, version: .v3)
                print("ModelHub path, \(name): loaded")
            } catch {
                print("ModelHub path, \(name): \(type(of: error)): \(error)")
            }
            do {
                _ = try AsrModels.loadLocal(from: directory, version: .v3)
                print("loadLocal, \(name): loaded")
            } catch {
                print("loadLocal, \(name): \(type(of: error)): \(error)")
            }
        }
        let digestAfter = (try? digest(of: broken)) ?? [:]
        print("broken folder unchanged: \(digestBefore == digestAfter) (\(digestBefore.count) files before, \(digestAfter.count) after)")
        try await Task.sleep(for: .seconds(3))
    }

    /// A request that must show up in the sampler, to prove the sampler sees traffic.
    static func netControl() async throws {
        print("pid \(getpid())")
        try await Task.sleep(for: .seconds(3))
        let (_, response) = try await Downloader.session.data(from: URL(string: "https://huggingface.co/api/models/FluidInference/silero-vad-coreml")!)
        print("control request: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        try await Task.sleep(for: .seconds(2))
    }

    private static func digest(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result[String(url.path.dropFirst(directory.path.count))] = try Downloader.sha256(of: url)
        }
        return result
    }

    static func appleSpeech() async {
        guard #available(macOS 26, *) else {
            print("SpeechTranscriber needs macOS 26")
            return
        }
        func line(_ title: String, _ locales: [Locale]) {
            let ids = Set(locales.map { $0.identifier(.bcp47) })
            let wanted = ["ru-RU", "uk-UA", "en-US", "be-BY"]
            print("\(title): \(ids.count) locales; " + wanted.map { "\($0)=\(ids.contains($0) ? "yes" : "no")" }.joined(separator: " "))
            print("  ru*/uk*/be*: " + ids.filter { $0.hasPrefix("ru") || $0.hasPrefix("uk") || $0.hasPrefix("be") }.sorted().joined(separator: ", "))
        }
        line("SpeechTranscriber.supportedLocales", await SpeechTranscriber.supportedLocales)
        line("SpeechTranscriber.installedLocales", await SpeechTranscriber.installedLocales)
        line("DictationTranscriber.supportedLocales", await DictationTranscriber.supportedLocales)
        line("DictationTranscriber.installedLocales", await DictationTranscriber.installedLocales)
        print("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
    }

    /// Writes `ModelCatalog.swift` from the manifests of downloaded models.
    static func catalog(output: String) throws {
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var out = """
            // SPDX-License-Identifier: GPL-3.0-or-later

            /// Draft catalog of speech model files: repositories pinned to a full commit,
            /// every file with its size and SHA-256. The numbers were measured by
            /// downloading each file from `resolve/<commit>/<file>`.
            public enum VoiceModelEngine: String, Sendable {
                case fluidAudioAsr
                case fluidAudioVad
                case fluidAudioDiarizer
                case whisperKit
            }

            public struct VoiceModelFile: Sendable, Equatable {
                /// Path inside the model folder.
                public let path: String
                /// Path inside the Hugging Face repository.
                public let remotePath: String
                public let size: Int64
                public let sha256: String
            }

            public struct VoiceModelSource: Sendable, Equatable {
                public let repo: String
                /// Full commit SHA.
                public let commit: String
                public let files: [VoiceModelFile]

                public func url(for file: VoiceModelFile) -> String {
                    "https://huggingface.co/\\(repo)/resolve/\\(commit)/\\(file.remotePath)?download=true"
                }
            }

            public struct VoiceModelEntry: Sendable, Equatable {
                public let id: String
                public let title: String
                public let engine: VoiceModelEngine
                /// BCP 47 codes; `*` means every language of the engine.
                public let languages: [String]
                public let sources: [VoiceModelSource]

                public var totalSize: Int64 { sources.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }
            }

            public enum ModelCatalog {
                public static func entry(id: String) -> VoiceModelEntry? { all.first { $0.id == id } }

                public static let all: [VoiceModelEntry] = [

            """
        for model in ProbeModels.all {
            let data = try Data(contentsOf: ProbePaths.manifest(model.id))
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            out += "        VoiceModelEntry(\n            id: \(quote(model.id)), title: \(quote(model.title)), engine: .\(model.engine),\n"
            out += "            languages: [\(model.languages.map(quote).joined(separator: ", "))],\n            sources: [\n"
            for source in manifest.sources {
                out += "                VoiceModelSource(\n                    repo: \(quote(source.repo)),\n                    commit: \(quote(source.commit)),\n                    files: [\n"
                for file in source.files {
                    out += "                        VoiceModelFile(\n                            path: \(quote(file.path)), remotePath: \(quote(file.remotePath)),\n                            size: \(file.size), sha256: \(quote(file.sha256))),\n"
                }
                out += "                    ]),\n"
            }
            out += "            ]),\n"
        }
        out += "    ]\n}\n"
        try out.write(toFile: output, atomically: true, encoding: .utf8)
        print("wrote \(output)")
    }
}
