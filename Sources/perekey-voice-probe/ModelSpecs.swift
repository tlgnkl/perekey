// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One Hugging Face repository pinned to a full commit SHA, and the files of it
/// that a model needs.
struct ProbeSource {
    let repo: String
    let commit: String
    /// A path matches when it equals an entry or lies below it.
    let include: [String]
    /// Folder prefix cut from the repository path before the file is stored.
    let strip: String
    /// Folder of the model directory that receives the files.
    let into: String

    init(repo: String, commit: String, include: [String], strip: String = "", into: String = "") {
        self.repo = repo
        self.commit = commit
        self.include = include
        self.strip = strip
        self.into = into
    }

    func matches(_ path: String) -> Bool {
        include.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func localPath(_ path: String) -> String {
        var relative = path
        if !strip.isEmpty, relative.hasPrefix(strip + "/") {
            relative = String(relative.dropFirst(strip.count + 1))
        }
        return into.isEmpty ? relative : into + "/" + relative
    }
}

struct ProbeModel {
    let id: String
    let title: String
    let engine: String
    let languages: [String]
    let role: String
    let sources: [ProbeSource]
}

/// Commits pinned on 2026-10-12 (heads of the `main` branches).
enum ProbeModels {
    static let parakeetFiles = [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc", "parakeet_vocab.json",
    ]

    static let parakeetLanguages = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    static let diarizerRepo = "FluidInference/speaker-diarization-coreml"
    static let diarizerCommit = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    static let whisperFolder = "openai_whisper-large-v3-v20240930_turbo_632MB"

    static let all: [ProbeModel] = [
        ProbeModel(
            id: "parakeet-tdt-v3", title: "Parakeet TDT 0.6B v3", engine: "fluidAudioAsr",
            languages: parakeetLanguages, role: "asr",
            sources: [
                ProbeSource(
                    repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                    commit: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe", include: parakeetFiles)
            ]),
        ProbeModel(
            id: "parakeet-ultra", title: "Parakeet Ultra", engine: "fluidAudioAsr",
            languages: parakeetLanguages, role: "asr",
            sources: [
                ProbeSource(
                    repo: "FluidInference/parakeet-ultra-coreml",
                    commit: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", include: parakeetFiles)
            ]),
        ProbeModel(
            id: "silero-vad", title: "Silero VAD 6.2.1", engine: "fluidAudioVad",
            languages: [], role: "vad",
            sources: [
                ProbeSource(
                    repo: "FluidInference/silero-vad-coreml",
                    commit: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
                    include: ["silero-vad-unified-256ms-v6.2.1.mlmodelc"])
            ]),
        ProbeModel(
            id: "diarizer-offline-vbx", title: "Offline diarizer (pyannote + VBx)",
            engine: "fluidAudioDiarizer", languages: [], role: "diarizer",
            sources: [
                ProbeSource(
                    repo: diarizerRepo, commit: diarizerCommit,
                    include: [
                        "Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc",
                        "PldaRho.mlmodelc", "plda-parameters.json",
                    ])
            ]),
        ProbeModel(
            id: "whisper-large-v3-turbo-632mb", title: "Whisper large-v3 turbo (632 MB)",
            engine: "whisperKit", languages: ["*"], role: "asr",
            sources: [
                ProbeSource(
                    repo: "argmaxinc/whisperkit-coreml",
                    commit: "0f63a7800b00dd0226abd051b906c246e1907482",
                    include: [whisperFolder], strip: whisperFolder),
                ProbeSource(
                    repo: "openai/whisper-large-v3",
                    commit: "06f233fe06e710322aca913c1bc4249a0d71fce1",
                    include: [
                        "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt",
                        "added_tokens.json", "special_tokens_map.json", "normalizer.json",
                        "config.json",
                    ], into: "tokenizer"),
            ]),
    ]

    static func find(_ id: String) -> ProbeModel? { all.first { $0.id == id } }
}
