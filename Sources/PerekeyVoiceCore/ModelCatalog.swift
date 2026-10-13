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
        "https://huggingface.co/\(repo)/resolve/\(commit)/\(file.remotePath)?download=true"
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
        VoiceModelEntry(
            id: "parakeet-tdt-v3", title: "Parakeet TDT 0.6B v3", engine: .fluidAudioAsr,
            languages: ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
                    commit: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
                    files: [
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/analytics/coremldata.bin", remotePath: "Decoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/coremldata.bin", remotePath: "Decoder.mlmodelc/coremldata.bin",
                            size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/metadata.json", remotePath: "Decoder.mlmodelc/metadata.json",
                            size: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/model.mil", remotePath: "Decoder.mlmodelc/model.mil",
                            size: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/weights/weight.bin", remotePath: "Decoder.mlmodelc/weights/weight.bin",
                            size: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/analytics/coremldata.bin", remotePath: "Encoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/coremldata.bin", remotePath: "Encoder.mlmodelc/coremldata.bin",
                            size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/metadata.json", remotePath: "Encoder.mlmodelc/metadata.json",
                            size: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/model.mil", remotePath: "Encoder.mlmodelc/model.mil",
                            size: 959769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/weights/weight.bin", remotePath: "Encoder.mlmodelc/weights/weight.bin",
                            size: 445187200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", remotePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/coremldata.bin", remotePath: "JointDecisionv3.mlmodelc/coremldata.bin",
                            size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/metadata.json", remotePath: "JointDecisionv3.mlmodelc/metadata.json",
                            size: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/model.mil", remotePath: "JointDecisionv3.mlmodelc/model.mil",
                            size: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/weights/weight.bin", remotePath: "JointDecisionv3.mlmodelc/weights/weight.bin",
                            size: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/analytics/coremldata.bin", remotePath: "Preprocessor.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/coremldata.bin", remotePath: "Preprocessor.mlmodelc/coremldata.bin",
                            size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/metadata.json", remotePath: "Preprocessor.mlmodelc/metadata.json",
                            size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/model.mil", remotePath: "Preprocessor.mlmodelc/model.mil",
                            size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/weights/weight.bin", remotePath: "Preprocessor.mlmodelc/weights/weight.bin",
                            size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                        VoiceModelFile(
                            path: "parakeet_vocab.json", remotePath: "parakeet_vocab.json",
                            size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "parakeet-ultra", title: "Parakeet Ultra", engine: .fluidAudioAsr,
            languages: ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/parakeet-ultra-coreml",
                    commit: "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
                    files: [
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/analytics/coremldata.bin", remotePath: "Decoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "fe92b6cfaa012abd5248c0bc877832f19807015abffc60d87b8ccc8ccb48b3b5"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/coremldata.bin", remotePath: "Decoder.mlmodelc/coremldata.bin",
                            size: 560, sha256: "3b06e66768f0df7e21795f50e2b29300e33eeb1a2579dc42c695279c2d308497"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/model.mil", remotePath: "Decoder.mlmodelc/model.mil",
                            size: 13110, sha256: "956f600207f88396017ca5c96cfa3acd5bfee60835a5b44b762e033a8fb28955"),
                        VoiceModelFile(
                            path: "Decoder.mlmodelc/weights/weight.bin", remotePath: "Decoder.mlmodelc/weights/weight.bin",
                            size: 23604992, sha256: "02a0d219f281b9665bc10c8768649403b2eebbbf4b44c627041d948e0de11bb4"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/analytics/coremldata.bin", remotePath: "Encoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "d87101d824d6723cf95304da33755c3c60e762663b9ef2b0c4bd0aa166a09a0d"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/coremldata.bin", remotePath: "Encoder.mlmodelc/coremldata.bin",
                            size: 514, sha256: "397a84a4062f563cbc5f56077c674f09a61d85be5090f61d2f1932afb92ac0fe"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/model.mil", remotePath: "Encoder.mlmodelc/model.mil",
                            size: 1002653, sha256: "f5d601568a4171d99a314c0fe3f6bc67715da2623732a3fb566e050ea83e5848"),
                        VoiceModelFile(
                            path: "Encoder.mlmodelc/weights/weight.bin", remotePath: "Encoder.mlmodelc/weights/weight.bin",
                            size: 594211328, sha256: "315ba01f33cadbf601d43ac7f5c86208b7aa75fdaa34705c9869d5abe3521c9b"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", remotePath: "JointDecisionv3.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "68d38ca646aebafa7a9329e2efda50f5767c49e89fdb5f77f212072bb66f97c4"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/coremldata.bin", remotePath: "JointDecisionv3.mlmodelc/coremldata.bin",
                            size: 592, sha256: "5e3af5a4ce686f6c237cadbd9284e10d333bc0e1546633cd0e430e6194044bc4"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/model.mil", remotePath: "JointDecisionv3.mlmodelc/model.mil",
                            size: 11777, sha256: "791b3c3cf3eb2079c84623fc880f6bba008d1366e5f8b03e9a8ed8bd4d7194a0"),
                        VoiceModelFile(
                            path: "JointDecisionv3.mlmodelc/weights/weight.bin", remotePath: "JointDecisionv3.mlmodelc/weights/weight.bin",
                            size: 12642764, sha256: "3f310b85b82341c53ec383025ab094a4e462ee1c592e1ad7c6bfe39cff66ca25"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/analytics/coremldata.bin", remotePath: "Preprocessor.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/coremldata.bin", remotePath: "Preprocessor.mlmodelc/coremldata.bin",
                            size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/metadata.json", remotePath: "Preprocessor.mlmodelc/metadata.json",
                            size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/model.mil", remotePath: "Preprocessor.mlmodelc/model.mil",
                            size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
                        VoiceModelFile(
                            path: "Preprocessor.mlmodelc/weights/weight.bin", remotePath: "Preprocessor.mlmodelc/weights/weight.bin",
                            size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
                        VoiceModelFile(
                            path: "parakeet_vocab.json", remotePath: "parakeet_vocab.json",
                            size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "silero-vad", title: "Silero VAD 6.2.1", engine: .fluidAudioVad,
            languages: [],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/silero-vad-coreml",
                    commit: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
                    files: [
                        VoiceModelFile(
                            path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin", remotePath: "silero-vad-unified-256ms-v6.2.1.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
                        VoiceModelFile(
                            path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin", remotePath: "silero-vad-unified-256ms-v6.2.1.mlmodelc/coremldata.bin",
                            size: 625, sha256: "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
                        VoiceModelFile(
                            path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json", remotePath: "silero-vad-unified-256ms-v6.2.1.mlmodelc/metadata.json",
                            size: 3335, sha256: "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
                        VoiceModelFile(
                            path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil", remotePath: "silero-vad-unified-256ms-v6.2.1.mlmodelc/model.mil",
                            size: 176918, sha256: "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
                        VoiceModelFile(
                            path: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin", remotePath: "silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin",
                            size: 882304, sha256: "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "diarizer-offline-vbx", title: "Offline diarizer (pyannote + VBx)", engine: .fluidAudioDiarizer,
            languages: [],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/speaker-diarization-coreml",
                    commit: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
                    files: [
                        VoiceModelFile(
                            path: "Embedding.mlmodelc/analytics/coremldata.bin", remotePath: "Embedding.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
                        VoiceModelFile(
                            path: "Embedding.mlmodelc/coremldata.bin", remotePath: "Embedding.mlmodelc/coremldata.bin",
                            size: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
                        VoiceModelFile(
                            path: "Embedding.mlmodelc/metadata.json", remotePath: "Embedding.mlmodelc/metadata.json",
                            size: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
                        VoiceModelFile(
                            path: "Embedding.mlmodelc/model.mil", remotePath: "Embedding.mlmodelc/model.mil",
                            size: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
                        VoiceModelFile(
                            path: "Embedding.mlmodelc/weights/weight.bin", remotePath: "Embedding.mlmodelc/weights/weight.bin",
                            size: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
                        VoiceModelFile(
                            path: "FBank.mlmodelc/analytics/coremldata.bin", remotePath: "FBank.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
                        VoiceModelFile(
                            path: "FBank.mlmodelc/coremldata.bin", remotePath: "FBank.mlmodelc/coremldata.bin",
                            size: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
                        VoiceModelFile(
                            path: "FBank.mlmodelc/metadata.json", remotePath: "FBank.mlmodelc/metadata.json",
                            size: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
                        VoiceModelFile(
                            path: "FBank.mlmodelc/model.mil", remotePath: "FBank.mlmodelc/model.mil",
                            size: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
                        VoiceModelFile(
                            path: "FBank.mlmodelc/weights/weight.bin", remotePath: "FBank.mlmodelc/weights/weight.bin",
                            size: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
                        VoiceModelFile(
                            path: "PldaRho.mlmodelc/analytics/coremldata.bin", remotePath: "PldaRho.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
                        VoiceModelFile(
                            path: "PldaRho.mlmodelc/coremldata.bin", remotePath: "PldaRho.mlmodelc/coremldata.bin",
                            size: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
                        VoiceModelFile(
                            path: "PldaRho.mlmodelc/metadata.json", remotePath: "PldaRho.mlmodelc/metadata.json",
                            size: 2749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
                        VoiceModelFile(
                            path: "PldaRho.mlmodelc/model.mil", remotePath: "PldaRho.mlmodelc/model.mil",
                            size: 7613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
                        VoiceModelFile(
                            path: "PldaRho.mlmodelc/weights/weight.bin", remotePath: "PldaRho.mlmodelc/weights/weight.bin",
                            size: 200192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
                        VoiceModelFile(
                            path: "Segmentation.mlmodelc/analytics/coremldata.bin", remotePath: "Segmentation.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
                        VoiceModelFile(
                            path: "Segmentation.mlmodelc/coremldata.bin", remotePath: "Segmentation.mlmodelc/coremldata.bin",
                            size: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
                        VoiceModelFile(
                            path: "Segmentation.mlmodelc/metadata.json", remotePath: "Segmentation.mlmodelc/metadata.json",
                            size: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
                        VoiceModelFile(
                            path: "Segmentation.mlmodelc/model.mil", remotePath: "Segmentation.mlmodelc/model.mil",
                            size: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
                        VoiceModelFile(
                            path: "Segmentation.mlmodelc/weights/weight.bin", remotePath: "Segmentation.mlmodelc/weights/weight.bin",
                            size: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
                        VoiceModelFile(
                            path: "plda-parameters.json", remotePath: "plda-parameters.json",
                            size: 89416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "diarizer-pyannote", title: "Online diarizer (pyannote + WeSpeaker)", engine: .fluidAudioDiarizer,
            languages: [],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/speaker-diarization-coreml",
                    commit: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
                    files: [
                        VoiceModelFile(
                            path: "pyannote_segmentation.mlmodelc/analytics/coremldata.bin", remotePath: "pyannote_segmentation.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "b379db0541b35344a34bb7540783ae704c11599bbed5aa8bbbda11c20ad215ee"),
                        VoiceModelFile(
                            path: "pyannote_segmentation.mlmodelc/coremldata.bin", remotePath: "pyannote_segmentation.mlmodelc/coremldata.bin",
                            size: 316, sha256: "4a450ea1b053b9eb7eef0cab6971018076600840c7e246d064e7c5387f456c98"),
                        VoiceModelFile(
                            path: "pyannote_segmentation.mlmodelc/metadata.json", remotePath: "pyannote_segmentation.mlmodelc/metadata.json",
                            size: 1763, sha256: "44e1fa36d6abafacf688beccad99f7569394248d8bb41545829997c67668c08c"),
                        VoiceModelFile(
                            path: "pyannote_segmentation.mlmodelc/model.mil", remotePath: "pyannote_segmentation.mlmodelc/model.mil",
                            size: 29490, sha256: "97f2dec6f83e80bf4247b98e13c2dde19f92c05820ef08068bbf554488d70bdd"),
                        VoiceModelFile(
                            path: "pyannote_segmentation.mlmodelc/weights/weight.bin", remotePath: "pyannote_segmentation.mlmodelc/weights/weight.bin",
                            size: 5734720, sha256: "0266f4ad4d843ecf31ef9220ad6b80616b3ec64a4404b64f3ea0371554e236ec"),
                        VoiceModelFile(
                            path: "wespeaker_v2.mlmodelc/analytics/coremldata.bin", remotePath: "wespeaker_v2.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"),
                        VoiceModelFile(
                            path: "wespeaker_v2.mlmodelc/coremldata.bin", remotePath: "wespeaker_v2.mlmodelc/coremldata.bin",
                            size: 359, sha256: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"),
                        VoiceModelFile(
                            path: "wespeaker_v2.mlmodelc/metadata.json", remotePath: "wespeaker_v2.mlmodelc/metadata.json",
                            size: 2738, sha256: "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"),
                        VoiceModelFile(
                            path: "wespeaker_v2.mlmodelc/model.mil", remotePath: "wespeaker_v2.mlmodelc/model.mil",
                            size: 706900, sha256: "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"),
                        VoiceModelFile(
                            path: "wespeaker_v2.mlmodelc/weights/weight.bin", remotePath: "wespeaker_v2.mlmodelc/weights/weight.bin",
                            size: 7243904, sha256: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "diarizer-sortformer", title: "Sortformer v2.1 (streaming and offline)", engine: .fluidAudioDiarizer,
            languages: [],
            sources: [
                VoiceModelSource(
                    repo: "FluidInference/diar-streaming-sortformer-coreml",
                    commit: "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
                    files: [
                        VoiceModelFile(
                            path: "v3/fp16/SortformerOffline_v2.1.mlmodelc/analytics/coremldata.bin", remotePath: "v3/fp16/SortformerOffline_v2.1.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "7a9cea3055d0916c7e46ea8dc4bd06a6db3e877b2ad9a8354c628137238d7ce9"),
                        VoiceModelFile(
                            path: "v3/fp16/SortformerOffline_v2.1.mlmodelc/coremldata.bin", remotePath: "v3/fp16/SortformerOffline_v2.1.mlmodelc/coremldata.bin",
                            size: 842, sha256: "181b9cc71c90caad0b465f0c513faf83427230fe304a4c82434b76eb11cc2cfd"),
                        VoiceModelFile(
                            path: "v3/fp16/SortformerOffline_v2.1.mlmodelc/model.mil", remotePath: "v3/fp16/SortformerOffline_v2.1.mlmodelc/model.mil",
                            size: 1734998, sha256: "3bbc2daaee50ef447f47917a82a79700804f977d0d25aff0ef9f393e915705af"),
                        VoiceModelFile(
                            path: "v3/fp16/SortformerOffline_v2.1.mlmodelc/weights/weight.bin", remotePath: "v3/fp16/SortformerOffline_v2.1.mlmodelc/weights/weight.bin",
                            size: 239846720, sha256: "6896b9f24eb084af26ca4b2e522df990ab4560c0dfaaf25d856e4eb945d10c12"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/analytics/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/analytics/coremldata.bin",
                            size: 202, sha256: "ad751275f22001fc74264b510c5aacde2706be37f983c0ba5c676c700abc51d7"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/coremldata.bin",
                            size: 1091, sha256: "5935b49ce40e428ee71257fbef03bb971ef3aba08e30667ccce6444205ae4752"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/analytics/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/analytics/coremldata.bin",
                            size: 108, sha256: "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/coremldata.bin",
                            size: 632, sha256: "0da04d1360e9dc8653deb610947d648710d4138d1f2229588e2c142ee473cf1f"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/model.mil", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/model.mil",
                            size: 31782, sha256: "f6b9b011973f566a8037664418abd87c3c878c2b5bcfaa86d4eceebcfba6b4df"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/weights/0-weight.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model0/weights/0-weight.bin",
                            size: 8948544, sha256: "88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/analytics/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/analytics/coremldata.bin",
                            size: 108, sha256: "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/coremldata.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/coremldata.bin",
                            size: 593, sha256: "cdce48459008f52883a2e512d78e81fe002b41a70f7cc5ecb969271866d2c650"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/model.mil", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/model.mil",
                            size: 1148078, sha256: "42f42882549ba1e3df7b74daee5d53f181c82e1475c551cc46aced242550ce38"),
                        VoiceModelFile(
                            path: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/weights/1-weight.bin", remotePath: "v3/fp16/Sortformer_v2.1.mlmodelc/model1/weights/1-weight.bin",
                            size: 230428224, sha256: "19802650a3d22c513a18290d789bbff4522c80aa2869c8865e56c3dd4a5a2404"),
                    ]),
            ]),
        VoiceModelEntry(
            id: "whisper-large-v3-turbo-632mb", title: "Whisper large-v3 turbo (632 MB)", engine: .whisperKit,
            languages: ["*"],
            sources: [
                VoiceModelSource(
                    repo: "argmaxinc/whisperkit-coreml",
                    commit: "0f63a7800b00dd0226abd051b906c246e1907482",
                    files: [
                        VoiceModelFile(
                            path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "0dd9f529c744ed3c6be67f699588f7aadc4f366b5b7301dc31bd3f199944fbcc"),
                        VoiceModelFile(
                            path: "AudioEncoder.mlmodelc/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/coremldata.bin",
                            size: 348, sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
                        VoiceModelFile(
                            path: "AudioEncoder.mlmodelc/metadata.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/metadata.json",
                            size: 1974, sha256: "2cd0538f90a012de3f07d38669026d527490eff1dcfd2479a81c48206a90f0a2"),
                        VoiceModelFile(
                            path: "AudioEncoder.mlmodelc/model.mil", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/model.mil",
                            size: 7589739, sha256: "ef5a252831e61bb91d6547fe1add3d0658895b518d47d70004322b40a2192668"),
                        VoiceModelFile(
                            path: "AudioEncoder.mlmodelc/weights/weight.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc/weights/weight.bin",
                            size: 421968768, sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
                        VoiceModelFile(
                            path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
                        VoiceModelFile(
                            path: "MelSpectrogram.mlmodelc/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/coremldata.bin",
                            size: 329, sha256: "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
                        VoiceModelFile(
                            path: "MelSpectrogram.mlmodelc/metadata.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/metadata.json",
                            size: 1850, sha256: "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
                        VoiceModelFile(
                            path: "MelSpectrogram.mlmodelc/model.mil", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/model.mil",
                            size: 10143, sha256: "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
                        VoiceModelFile(
                            path: "MelSpectrogram.mlmodelc/weights/weight.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/MelSpectrogram.mlmodelc/weights/weight.bin",
                            size: 373376, sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
                        VoiceModelFile(
                            path: "TextDecoder.mlmodelc/analytics/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "4b5119bdc621c3c494f63846dc3ed43852e88826fc3b6345d42272d4b7e67724"),
                        VoiceModelFile(
                            path: "TextDecoder.mlmodelc/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/coremldata.bin",
                            size: 633, sha256: "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
                        VoiceModelFile(
                            path: "TextDecoder.mlmodelc/metadata.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/metadata.json",
                            size: 4924, sha256: "e3ce6d83884552ffcc2c34799e8e1211dcda59f1aaea5a79bf988c6cd16abbf0"),
                        VoiceModelFile(
                            path: "TextDecoder.mlmodelc/model.mil", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/model.mil",
                            size: 217177, sha256: "ebaf8566f367b6465276c3ed57bb99063888fa955b67828585bf19db24c85f56"),
                        VoiceModelFile(
                            path: "TextDecoder.mlmodelc/weights/weight.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoder.mlmodelc/weights/weight.bin",
                            size: 203199860, sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
                        VoiceModelFile(
                            path: "TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin",
                            size: 243, sha256: "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
                        VoiceModelFile(
                            path: "TextDecoderContextPrefill.mlmodelc/coremldata.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/coremldata.bin",
                            size: 380, sha256: "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
                        VoiceModelFile(
                            path: "TextDecoderContextPrefill.mlmodelc/metadata.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/metadata.json",
                            size: 2240, sha256: "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068"),
                        VoiceModelFile(
                            path: "TextDecoderContextPrefill.mlmodelc/model.mil", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/model.mil",
                            size: 4092, sha256: "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34"),
                        VoiceModelFile(
                            path: "TextDecoderContextPrefill.mlmodelc/weights/weight.bin", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/TextDecoderContextPrefill.mlmodelc/weights/weight.bin",
                            size: 12288192, sha256: "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
                        VoiceModelFile(
                            path: "config.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/config.json",
                            size: 1149, sha256: "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
                        VoiceModelFile(
                            path: "generation_config.json", remotePath: "openai_whisper-large-v3-v20240930_turbo_632MB/generation_config.json",
                            size: 2767, sha256: "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
                    ]),
                VoiceModelSource(
                    repo: "openai/whisper-large-v3",
                    commit: "06f233fe06e710322aca913c1bc4249a0d71fce1",
                    files: [
                        VoiceModelFile(
                            path: "tokenizer/added_tokens.json", remotePath: "added_tokens.json",
                            size: 34648, sha256: "3c51f66c4c21f9e126970078f11ae77a78c74aee8df606ee9daba86e467108e0"),
                        VoiceModelFile(
                            path: "tokenizer/config.json", remotePath: "config.json",
                            size: 1272, sha256: "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b"),
                        VoiceModelFile(
                            path: "tokenizer/merges.txt", remotePath: "merges.txt",
                            size: 493869, sha256: "2df2990a395e35e8dfbc7511e08c12d56018d8d04691e0133e5d63b21e154dc6"),
                        VoiceModelFile(
                            path: "tokenizer/normalizer.json", remotePath: "normalizer.json",
                            size: 52666, sha256: "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd"),
                        VoiceModelFile(
                            path: "tokenizer/special_tokens_map.json", remotePath: "special_tokens_map.json",
                            size: 2072, sha256: "1c70773c078cb2ca96e0fcff113102f1d3e2b1504272c3bb63b035d4a6700d87"),
                        VoiceModelFile(
                            path: "tokenizer/tokenizer.json", remotePath: "tokenizer.json",
                            size: 2480617, sha256: "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
                        VoiceModelFile(
                            path: "tokenizer/tokenizer_config.json", remotePath: "tokenizer_config.json",
                            size: 282843, sha256: "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
                        VoiceModelFile(
                            path: "tokenizer/vocab.json", remotePath: "vocab.json",
                            size: 1036558, sha256: "e2aa043ef015641d363d8288e7c241c85e36a5c761fb303598e0710233344387"),
                    ]),
            ]),
    ]
}
