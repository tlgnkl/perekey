// SPDX-License-Identifier: GPL-3.0-or-later

/// The engine that loads a model, and so what the model is for.
public enum VoiceModelEngine: String, Sendable {
    case fluidAudioAsr
    case fluidAudioVad
    case fluidAudioDiarizer
    case whisperKit

    /// Speech to text: the models a user picks for dictation.
    public var recognizes: Bool { self == .fluidAudioAsr || self == .whisperKit }
}

public struct VoiceModelFile: Sendable, Equatable {
    /// Path inside the model folder.
    public let path: String
    /// Path inside the Hugging Face repository.
    public let remotePath: String
    public let size: Int64
    /// Lowercase hex.
    public let sha256: String

    public init(path: String, remotePath: String? = nil, size: Int64, sha256: String) {
        self.path = path
        self.remotePath = remotePath ?? path
        self.size = size
        self.sha256 = sha256
    }
}

/// A Hugging Face repository pinned to a full commit, and the files a model
/// takes from it.
public struct VoiceModelSource: Sendable, Equatable {
    public let repo: String
    /// Full commit SHA.
    public let commit: String
    public let files: [VoiceModelFile]

    public init(repo: String, commit: String, files: [VoiceModelFile]) {
        self.repo = repo
        self.commit = commit
        self.files = files
    }

    /// `<host>/<repo>/resolve/<commit>/<file>?download=true`, the path
    /// percent-encoded segment by segment. Hugging Face redirects it to its CDN
    /// with a signed link that expires; this address stays valid.
    public func url(for file: VoiceModelFile, host: String = ModelCatalog.host) -> String {
        let path = file.remotePath.split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncoded(String($0)) }
            .joined(separator: "/")
        return "\(host)/\(repo)/resolve/\(commit)/\(path)?download=true"
    }

    /// What "Download" names as the address: the repository page at the commit.
    public var pageURL: String { "\(ModelCatalog.host)/\(repo)/tree/\(commit)" }
}

public struct VoiceModelEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let engine: VoiceModelEngine
    /// BCP 47 codes; `*` means every language of the engine.
    public let languages: [String]
    /// Several when a model takes parts from different repositories: Whisper
    /// takes its tokenizer from the OpenAI repository into `tokenizer/`.
    public let sources: [VoiceModelSource]

    public init(id: String, title: String, engine: VoiceModelEngine, languages: [String], sources: [VoiceModelSource]) {
        self.id = id
        self.title = title
        self.engine = engine
        self.languages = languages
        self.sources = sources
    }

    public var totalSize: Int64 { sources.reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } } }

    public var fileCount: Int { sources.reduce(0) { $0 + $1.files.count } }
}

/// The speech models Perekey can download: each repository pinned to a full
/// commit, every file with its size and SHA-256. The list changes only with a
/// release of Perekey; nothing is fetched to update it.
public enum ModelCatalog {
    /// Bumped whenever a release changes `all`.
    public static let version = 1

    /// Where the files come from. Hugging Face redirects downloads to
    /// `cdn-lfs.hf.co` and `cas-bridge.xethub.hf.co`.
    public static let host = "https://huggingface.co"

    public static func entry(id: String) -> VoiceModelEntry? { all.first { $0.id == id } }

    /// Speech to text, for dictation and files.
    public static var recognizers: [VoiceModelEntry] { all.filter(\.engine.recognizes) }

    /// Silero VAD: downloaded together with the first recognizer.
    public static var vad: VoiceModelEntry? { all.first { $0.engine == .fluidAudioVad } }

    public static var diarizers: [VoiceModelEntry] { all.filter { $0.engine == .fluidAudioDiarizer } }
}

/// RFC 3986 percent-encoding of one path segment: everything but unreserved
/// characters and sub-delimiters goes as `%XX` of its UTF-8 bytes.
func percentEncoded(_ segment: String) -> String {
    var out = ""
    for byte in segment.utf8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            out.unicodeScalars.append(Unicode.Scalar(byte))
        case _ where "-._~!$&'()*+,;=:@".utf8.contains(byte):
            out.unicodeScalars.append(Unicode.Scalar(byte))
        default:
            let hex = Array("0123456789ABCDEF".utf8)
            out += "%"
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte >> 4)]))
            out.unicodeScalars.append(Unicode.Scalar(hex[Int(byte & 0xF)]))
        }
    }
    return out
}
