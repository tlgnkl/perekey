// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyVoice
import Testing

struct StoreWhisperKitTests {
    private func folder(tokenizer: String?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "whisper-\(UUID().uuidString)")
        let tokenizerFolder = folder.appending(path: "tokenizer")
        try FileManager.default.createDirectory(at: tokenizerFolder, withIntermediateDirectories: true)
        if let tokenizer {
            try Data(tokenizer.utf8).write(to: tokenizerFolder.appending(path: "tokenizer.json"))
            try Data(#"{"tokenizer_class":"WhisperTokenizer"}"#.utf8)
                .write(to: tokenizerFolder.appending(path: "tokenizer_config.json"))
        }
        return folder
    }

    @Test(arguments: [nil, "{ not json", #"{"model":{"type":"BPE","vocab":{"a":0},"merges":[]}}"#])
    func aBrokenTokenizerIsAModelError(_ tokenizer: String?) async throws {
        let folder = try folder(tokenizer: tokenizer)
        defer { try? FileManager.default.removeItem(at: folder) }
        // It fails before WhisperKit or CoreML: the folder has no models at all.
        await #expect(throws: WhisperTokenizerError.self) {
            _ = try await WhisperKitEngine.load(from: folder)
        }
    }

    /// The real tokenizer, where the probe downloaded it; skipped elsewhere.
    static let probeTokenizer = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Caches/perekey-voice-probe/whisper-large-v3-turbo-632mb/tokenizer")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: probeTokenizer.path)))
    func theWhisperTokenizer() async throws {
        let tokenizer = try await LocalWhisperTokenizer(folder: Self.probeTokenizer)
        #expect(tokenizer.specialTokens.startOfTranscriptToken == 50258)
        #expect(tokenizer.specialTokens.transcribeToken == 50360)
        #expect(tokenizer.allLanguageTokens.count == 100)
        #expect(tokenizer.convertTokenToId("<|ru|>").map(tokenizer.allLanguageTokens.contains) == true)
        let special = tokenizer.specialTokens.specialTokenBegin
        let ids = tokenizer.encode(text: " Привет, мир").filter { $0 < special }
        #expect(tokenizer.decode(tokens: ids) == " Привет, мир")
        let split = tokenizer.splitToWordTokens(tokenIds: ids)
        #expect(split.words == [" Привет", ",", " мир"])
        #expect(split.wordTokens.flatMap { $0 } == ids)
    }
}
