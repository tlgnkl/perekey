// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyVoice
import Security
import PerekeyVoiceCore
import Testing

/// A fake OpenAI-compatible server (what Ollama and LM Studio serve) on
/// 127.0.0.1, and a `VoiceHTTP` open for it.
struct FakeOpenAI {
    let server: TestServer
    let http: VoiceHTTP
    var address: EndpointAddress { EndpointAddress("\(server.base)/v1")! }

    init(_ handler: @escaping TestServer.Handler = FakeOpenAI.answer("Привет, мир.")) async throws {
        server = try await TestServer(handler)
        http = VoiceHTTP(allowed: [.cloudLanguageModel, .cloudSpeech])
        let origin = EndpointAddress("\(server.base)/v1")!.origin
        http.allowedOrigins = [.cloudLanguageModel: [origin], .cloudSpeech: [origin]]
    }

    func client(timeout: Duration = .seconds(10)) -> OpenAICompatibleClient {
        OpenAICompatibleClient(http: http, timeout: timeout)
    }

    static func answer(_ text: String) -> TestServer.Handler {
        { request, _ in
            if request.path.hasSuffix("/audio/transcriptions") {
                return json(["text": text])
            }
            return json(["id": "x", "choices": [["index": 0, "message": ["role": "assistant", "content": text]]]])
        }
    }

    static func json(_ object: Any, status: Int = 200) -> TestServer.Response {
        TestServer.Response(status: status, headers: ["Content-Type": "application/json"],
                            body: try! JSONSerialization.data(withJSONObject: object))
    }

    /// The chat request's JSON body.
    static func body(_ request: TestServer.Request) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
    }
}

struct OpenAICompatibleClientTests {
    let messages = [ChatMessage(role: .system, content: "Fix it."), ChatMessage(role: .user, content: "привет мир")]

    @Test func chatCompletion() async throws {
        let fake = try await FakeOpenAI()
        let text = try await fake.client().complete(messages, model: "qwen2.5:7b", address: fake.address, key: "sk-test", purpose: .cloudLanguageModel)
        #expect(text == "Привет, мир.")
        let request = try #require(fake.server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer sk-test")
        #expect(request.headers["content-type"] == "application/json")
        let body = FakeOpenAI.body(request)
        #expect(body["model"] as? String == "qwen2.5:7b")
        #expect(body["stream"] as? Bool == false)
        let sent = body["messages"] as? [[String: String]]
        #expect(sent == [["role": "system", "content": "Fix it."], ["role": "user", "content": "привет мир"]])
        #expect(fake.http.requests == [VoiceHTTP.Request(host: "127.0.0.1", purpose: .cloudLanguageModel)])
    }

    @Test func noKeyNoHeader() async throws {
        let fake = try await FakeOpenAI()
        _ = try await fake.client().complete(messages, model: "m", address: fake.address, key: nil, purpose: .cloudLanguageModel)
        #expect(fake.server.requests.first?.headers["authorization"] == nil)
    }

    @Test func errorsAreTyped() async throws {
        let cases: [(TestServer.Response, OpenAICompatibleClient.Failure)] = [
            (FakeOpenAI.json(["error": ["message": "Incorrect API key"]], status: 401), .unauthorized),
            (FakeOpenAI.json([:], status: 403), .unauthorized),
            (FakeOpenAI.json(["error": ["message": "model not found"]], status: 404), .notFound),
            (FakeOpenAI.json([:], status: 429), .rateLimited),
            (FakeOpenAI.json(["error": ["message": "boom\nsecond line"]], status: 500),
             .server(status: 500, message: "boom second line")),
            (FakeOpenAI.json(["choices": []]), .badResponse),
            (TestServer.Response(status: 200, body: Data("not json".utf8)), .badResponse),
        ]
        for (response, failure) in cases {
            let fake = try await FakeOpenAI { _, _ in response }
            await #expect(throws: failure) {
                try await fake.client().complete(messages, model: "m", address: fake.address, key: "k", purpose: .cloudLanguageModel)
            }
        }
    }

    @Test func aStalledServerTimesOut() async throws {
        let fake = try await FakeOpenAI { _, _ in TestServer.Response(status: 200, body: Data(count: 100), cutAfter: 1, stall: true) }
        let start = ContinuousClock.now
        await #expect(throws: OpenAICompatibleClient.Failure.timedOut) {
            try await fake.client(timeout: .milliseconds(300)).complete(messages, model: "m", address: fake.address, key: nil, purpose: .cloudLanguageModel)
        }
        // The server never finishes: the 300 ms timeout ended the request, not
        // URLSession's own 60 s. Generous, since a busy machine runs tests slowly.
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func anOriginNotAllowedIsNeverReached() async throws {
        let fake = try await FakeOpenAI()
        fake.http.allowedOrigins = [.cloudLanguageModel: ["https://api.openai.com:443"]]
        await #expect(throws: OpenAICompatibleClient.Failure.blocked) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "k", purpose: .cloudLanguageModel)
        }
        // Consent to the audio is not consent to the text.
        fake.http.allowedOrigins = [.cloudSpeech: [fake.address.origin]]
        await #expect(throws: OpenAICompatibleClient.Failure.blocked) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "k", purpose: .cloudLanguageModel)
        }
        // The purpose closed: blocked as well.
        fake.http.allowedOrigins = [.cloudLanguageModel: [fake.address.origin]]
        fake.http.allowed = [.modelDownload]
        await #expect(throws: OpenAICompatibleClient.Failure.blocked) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "k", purpose: .cloudLanguageModel)
        }
        #expect(fake.server.requests.isEmpty)
        #expect(fake.http.requests.isEmpty)
    }

    @Test func aRedirectIsNotFollowedAndTheKeyStays() async throws {
        let other = try await TestServer { _, _ in FakeOpenAI.json(["choices": []]) }
        let fake = try await FakeOpenAI { _, _ in
            TestServer.Response(status: 302, headers: ["Location": "\(other.base)/v1/chat/completions"])
        }
        // Even an origin the gate would let out is not followed to.
        fake.http.allowedOrigins[.cloudLanguageModel]?.insert(EndpointAddress("\(other.base)/v1")!.origin)
        await #expect(throws: OpenAICompatibleClient.Failure.badResponse) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "sk-secret", purpose: .cloudLanguageModel)
        }
        #expect(fake.server.requests.count == 1)
        #expect(other.requests.isEmpty, "the second server got neither a request nor the key")
    }

    @Test func anOversizedAnswerIsCut() async throws {
        let fake = try await FakeOpenAI { _, _ in TestServer.Response(status: 200, body: Data(count: VoiceHTTP.dataLimit + 1)) }
        await #expect(throws: OpenAICompatibleClient.Failure.badResponse) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: nil, purpose: .cloudLanguageModel)
        }
        await #expect(throws: VoiceHTTP.Failure.tooLarge) {
            _ = try await fake.http.data(for: URLRequest(url: URL(string: fake.address.url("/x"))!),
                                         purpose: .cloudLanguageModel, limit: 10)
        }
    }

    @Test func closingTheOriginCancelsTheRequest() async throws {
        let fake = try await FakeOpenAI { _, _ in TestServer.Response(status: 200, body: Data(count: 100), cutAfter: 1, stall: true) }
        let client = fake.client(timeout: .seconds(30))
        let address = fake.address
        let messages = self.messages
        let request = Task { try await client.complete(messages, model: "m", address: address, key: nil, purpose: .cloudLanguageModel) }
        let server = fake.server
        try await waitUntil { !server.requests.isEmpty }
        let start = ContinuousClock.now
        // Consent revoked while the model thinks.
        fake.http.allowedOrigins = [:]
        await #expect(throws: (any Error).self) { try await request.value }
        // Well under the 30 s timeout: closing the origin ended the request.
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func theTranscriptionWaitGrowsWithTheUpload() {
        #expect(OpenAICompatibleClient.transcriptionTimeout(bytes: 0) == .seconds(30))
        #expect(OpenAICompatibleClient.transcriptionTimeout(bytes: 100_000) == .seconds(31))
        // Ten minutes of 16 kHz audio, the longest dictation: about 19 MB.
        #expect(OpenAICompatibleClient.transcriptionTimeout(bytes: 19_200_044) > .seconds(220))
    }

    @Test func transcription() async throws {
        let fake = try await FakeOpenAI(FakeOpenAI.answer("Привет из облака."))
        let audio = AudioBuffer16k([Float](repeating: 0.25, count: 1_600))
        let text = try await fake.client().transcribe(audio, model: "whisper-large-v3-turbo", address: fake.address,
                                                      key: "gsk-test")
        #expect(text == "Привет из облака.")
        let request = try #require(fake.server.requests.first)
        #expect(request.path == "/v1/audio/transcriptions")
        #expect(request.headers["authorization"] == "Bearer gsk-test")
        #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: request.body, as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        #expect(body.contains("filename=\"dictation.wav\""))
        #expect(request.body.range(of: Data("RIFF".utf8)) != nil)
        #expect(fake.http.requests.map(\.purpose) == [.cloudSpeech])
    }

    @Test func cloudSpeechEngine() async throws {
        let fake = try await FakeOpenAI(FakeOpenAI.answer("Облако."))
        let address = fake.address
        let engine = CloudSTTEngine(model: CloudSpeechModel(endpoint: "groq", model: "whisper-large-v3-turbo"),
                                    client: fake.client()) { .init(address: address, key: "k") }
        #expect(engine.id == "cloud:groq:whisper-large-v3-turbo")
        try await engine.prepare()
        #expect(try await engine.transcribe(AudioBuffer16k([0, 0.1])).text == "Облако.")
        // The dictionary's words go as the request's prompt; none, no field.
        _ = try await engine.transcribe(AudioBuffer16k([0, 0.1]), prompt: "Perekey, Parakeet")
        let bodies = fake.server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(!bodies[0].contains("name=\"prompt\""))
        #expect(bodies[1].contains("name=\"prompt\"\r\n\r\nPerekey, Parakeet\r\n"))
        let gone = CloudSTTEngine(model: CloudSpeechModel(endpoint: "groq", model: "m"), client: fake.client()) { nil }
        await #expect(throws: CloudSTTEngine.Failure.unavailable) { try await gone.transcribe(AudioBuffer16k([0])) }
    }

    /// Files: Whisper's phrases keep their timings; a gpt-4o answer without
    /// them is one phrase from the start of the piece.
    @Test func timedTranscription() async throws {
        let fake = try await FakeOpenAI { request, _ in
            let body = String(decoding: request.body, as: UTF8.self)
            if body.contains("verbose_json") {
                return FakeOpenAI.json(["text": "Раз. Два.", "language": "russian",
                             "segments": [["start": 0.5, "end": 1.5, "text": " Раз."],
                                          ["start": 2.0, "end": 3.0, "text": " Два."]]])
            }
            return FakeOpenAI.json(["text": "Всё сразу."])
        }
        let audio = AudioBuffer16k([Float](repeating: 0, count: 64_000))
        let whisper = try await fake.client().transcribeTimed(audio, model: "whisper-1", address: fake.address,
                                                              key: nil, language: "ru", prompt: "Perekey")
        #expect(whisper.segments.map(\.text) == ["Раз.", "Два."])
        #expect(whisper.segments.map(\.start) == [0.5, 2.0])
        #expect(whisper.language == "ru")
        let gpt = try await fake.client().transcribeTimed(audio, model: "gpt-4o-transcribe", address: fake.address,
                                                          key: nil, language: nil, prompt: nil)
        #expect(gpt.segments == [TimedSegment(start: 0, end: 4, text: "Всё сразу.")])
        #expect(gpt.language == nil)
        let bodies = fake.server.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(bodies[0].contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment\r\n"))
        #expect(bodies[0].contains("name=\"language\"\r\n\r\nru\r\n"))
        #expect(bodies[0].contains("name=\"prompt\"\r\n\r\nPerekey\r\n"))
        #expect(bodies[1].contains("name=\"response_format\"\r\n\r\njson\r\n"))
        #expect(!bodies[1].contains("timestamp_granularities"))
    }

    @Test func wavHeader() {
        let wav = WAV.encode(AudioBuffer16k([0, 1, -1, 2]))
        #expect(wav.count == 44 + 8)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let samples = wav[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [0, Int16.max, -Int16.max, Int16.max])
    }
}

struct VoiceKeychainTests {
    /// A keychain file of its own, unlocked, removed after the test: the
    /// login keychain is not touched, and need not be reachable.
    @Test func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "perekey-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "test.keychain-db").path
        let password = "perekey-test"
        var file: SecKeychain?
        // SecKeychainCreate is deprecated, and the only way to a keychain file
        // of one's own that needs no user interaction.
        let created = password.withCString { SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &file) }
        try #require(created == errSecSuccess)
        let made = try #require(file)
        defer { SecKeychainDelete(made) }
        let keychain = VoiceKeychain(service: "app.perekey.tests.\(UUID().uuidString)", keychain: made)
        defer { try? keychain.removeAll() }
        #expect(try keychain.key(for: "openai") == nil)
        #expect(!keychain.hasKey(for: "openai"))
        try keychain.set("  sk-first\n", for: "openai")
        #expect(try keychain.key(for: "openai") == "sk-first")
        #expect(keychain.hasKey(for: "openai"))
        try keychain.set("sk-second", for: "openai")
        #expect(try keychain.key(for: "openai") == "sk-second")
        try keychain.set("gsk", for: "groq")
        #expect(try keychain.key(for: "groq") == "gsk")
        try keychain.remove("openai")
        #expect(try keychain.key(for: "openai") == nil)
        #expect(try keychain.key(for: "groq") == "gsk")
        // An empty key removes it.
        try keychain.set(" ", for: "groq")
        #expect(!keychain.hasKey(for: "groq"))
        try keychain.remove("never-there")
    }
}

struct VoiceHTTPOriginTests {
    @Test func origins() {
        #expect(VoiceHTTP.origin(of: URL(string: "https://api.openai.com/v1/chat/completions")!) == "https://api.openai.com:443")
        #expect(VoiceHTTP.origin(of: URL(string: "http://LOCALHOST:11434/v1")!) == "http://localhost:11434")
        #expect(VoiceHTTP.origin(of: URL(string: "http://[::1]:1234/v1")!) == EndpointAddress("http://[::1]:1234/v1")?.origin)
        #expect(VoiceHTTP.origin(of: URL(string: "ftp://x.com")!) == nil)
    }

    @Test func policyOpensOnlyConsentedAndLocalOrigins() {
        var modes = VoiceModeSet.defaults()
        let managed = ManagedSettings()
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: managed, modes: modes)
            == [.modelDownload, .cloudSpeech, .cloudLanguageModel, .conversationLanguageModel])
        let local: Set = ["http://localhost:11434", "http://localhost:1234"]
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: managed, modes: modes)
            == [.cloudSpeech: local, .cloudLanguageModel: local, .conversationLanguageModel: local])
        modes.consent([.text], endpoint: "openai")
        let origins = VoiceNetworkPolicy.origins(isEnabled: true, managed: managed, modes: modes)
        #expect(origins[.cloudLanguageModel]?.contains("https://api.openai.com:443") == true)
        #expect(origins[.cloudSpeech]?.contains("https://api.openai.com:443") == false, "the text, not the audio")
        // The cloud off by the profile: this Mac only.
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: ManagedSettings(voiceCloudDisabled: true), modes: modes)
            == [.cloudSpeech: local, .cloudLanguageModel: local, .conversationLanguageModel: local])
        // Downloads off by the profile: language models still work.
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceModelDownloadsDisabled: true),
                                           modes: modes) == [.cloudSpeech, .cloudLanguageModel, .conversationLanguageModel])
        // Voice off, or off by the profile: nothing.
        #expect(VoiceNetworkPolicy.allowed(isEnabled: false, managed: managed, modes: modes).isEmpty)
        #expect(VoiceNetworkPolicy.origins(isEnabled: false, managed: managed, modes: modes).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceDisabled: true), modes: modes).isEmpty)
        let http = VoiceHTTP()
        VoiceNetworkPolicy.apply(isEnabled: true, managed: managed, modes: modes, to: http)
        #expect(http.allowedOrigins[.cloudLanguageModel]?.contains("https://api.openai.com:443") == true)
        VoiceNetworkPolicy.apply(isEnabled: false, managed: managed, modes: modes, to: http)
        #expect(http.allowedOrigins.isEmpty && http.allowed.isEmpty)
    }
}
