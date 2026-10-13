// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyVoiceCore
import Testing

struct ModelCatalogTests {
    private func isHex(_ text: String, count: Int) -> Bool {
        text.count == count && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    @Test func everyFileIsPinnedAndChecked() {
        #expect(ModelCatalog.version >= 1)
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
        for entry in ModelCatalog.all {
            #expect(!entry.sources.isEmpty && entry.totalSize > 0, "\(entry.id)")
            var paths = Set<String>()
            for source in entry.sources {
                #expect(isHex(source.commit, count: 40), "\(entry.id): \(source.commit)")
                for file in source.files {
                    #expect(isHex(file.sha256, count: 64), "\(entry.id): \(file.path)")
                    #expect(file.size > 0, "\(entry.id): \(file.path)")
                    #expect(paths.insert(file.path).inserted, "\(entry.id): \(file.path) twice")
                    // Paths stay inside the model folder.
                    for path in [file.path, file.remotePath] {
                        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                        #expect(!path.hasPrefix("/") && !parts.contains("..") && !parts.contains("") && !parts.contains("."), "\(path)")
                        #expect(!path.hasSuffix(".part") && !path.hasPrefix(".perekey"), "\(path)")
                    }
                }
            }
        }
    }

    @Test func selections() throws {
        #expect(ModelCatalog.vad?.id == "silero-vad")
        #expect(ModelCatalog.recognizers.map(\.id) == ["parakeet-tdt-v3", "parakeet-ultra", "whisper-large-v3-turbo-632mb"])
        #expect(ModelCatalog.diarizers.count == 3)
        #expect(ModelCatalog.entry(id: "parakeet-tdt-v3")?.languages.contains("uk") == true)
        #expect(ModelCatalog.entry(id: "nope") == nil)
    }

    /// WhisperKit takes the whole folder, the tokenizer from OpenAI's repository inside it.
    @Test func whisperBringsItsTokenizer() throws {
        let whisper = try #require(ModelCatalog.entry(id: "whisper-large-v3-turbo-632mb"))
        #expect(whisper.sources.count == 2)
        let tokenizer = whisper.sources[1]
        #expect(tokenizer.repo == "openai/whisper-large-v3")
        #expect(tokenizer.files.allSatisfy { $0.path == "tokenizer/" + $0.remotePath })
        #expect(whisper.sources[0].files.allSatisfy { $0.remotePath.hasSuffix("/" + $0.path) })
    }

    @Test func remotePathDefaultsToPath() {
        let file = VoiceModelFile(path: "a/b.bin", size: 1, sha256: "")
        #expect(file.remotePath == "a/b.bin")
        #expect(VoiceModelFile(path: "tokenizer/x", remotePath: "x", size: 1, sha256: "").remotePath == "x")
    }

    @Test func addressesArePercentEncoded() {
        let source = VoiceModelSource(repo: "org/repo", commit: "c0ffee", files: [])
        let plain = VoiceModelFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 1, sha256: "")
        #expect(source.url(for: plain) == "https://huggingface.co/org/repo/resolve/c0ffee/Encoder.mlmodelc/weights/weight.bin?download=true")
        let odd = VoiceModelFile(path: "x", remotePath: "with space/é?#%.json", size: 1, sha256: "")
        #expect(source.url(for: odd, host: "http://127.0.0.1:8080")
            == "http://127.0.0.1:8080/org/repo/resolve/c0ffee/with%20space/%C3%A9%3F%23%25.json?download=true")
        #expect(source.pageURL == "https://huggingface.co/org/repo/tree/c0ffee")
        #expect(percentEncoded("a-b_c.d~e") == "a-b_c.d~e")
    }
}
