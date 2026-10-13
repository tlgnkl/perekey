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
        http.allowedOrigins = [EndpointAddress("\(server.base)/v1")!.origin]
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
        let text = try await fake.client().complete(messages, model: "qwen2.5:7b", address: fake.address, key: "sk-test")
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
        _ = try await fake.client().complete(messages, model: "m", address: fake.address, key: nil)
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
                try await fake.client().complete(messages, model: "m", address: fake.address, key: "k")
            }
        }
    }

    @Test func aStalledServerTimesOut() async throws {
        let fake = try await FakeOpenAI { _, _ in TestServer.Response(status: 200, body: Data(count: 100), cutAfter: 1, stall: true) }
        let start = ContinuousClock.now
        await #expect(throws: OpenAICompatibleClient.Failure.timedOut) {
            try await fake.client(timeout: .milliseconds(300)).complete(messages, model: "m", address: fake.address, key: nil)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func anOriginNotAllowedIsNeverReached() async throws {
        let fake = try await FakeOpenAI()
        fake.http.allowedOrigins = ["https://api.openai.com:443"]
        await #expect(throws: OpenAICompatibleClient.Failure.blocked) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "k")
        }
        // The purpose closed: blocked as well.
        fake.http.allowedOrigins = [fake.address.origin]
        fake.http.allowed = [.modelDownload]
        await #expect(throws: OpenAICompatibleClient.Failure.blocked) {
            try await fake.client().complete(messages, model: "m", address: fake.address, key: "k")
        }
        #expect(fake.server.requests.isEmpty)
        #expect(fake.http.requests.isEmpty)
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
        let gone = CloudSTTEngine(model: CloudSpeechModel(endpoint: "groq", model: "m"), client: fake.client()) { nil }
        await #expect(throws: CloudSTTEngine.Failure.unavailable) { try await gone.transcribe(AudioBuffer16k([0])) }
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
            == [.modelDownload, .cloudSpeech, .cloudLanguageModel])
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: managed, modes: modes)
            == ["http://localhost:11434", "http://localhost:1234"])
        modes.consent([.text], endpoint: "openai")
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: managed, modes: modes)
            .contains("https://api.openai.com:443"))
        // The cloud off by the profile: this Mac only.
        #expect(VoiceNetworkPolicy.origins(isEnabled: true, managed: ManagedSettings(voiceCloudDisabled: true), modes: modes)
            == ["http://localhost:11434", "http://localhost:1234"])
        // Downloads off by the profile: language models still work.
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceModelDownloadsDisabled: true),
                                           modes: modes) == [.cloudSpeech, .cloudLanguageModel])
        // Voice off, or off by the profile: nothing.
        #expect(VoiceNetworkPolicy.allowed(isEnabled: false, managed: managed, modes: modes).isEmpty)
        #expect(VoiceNetworkPolicy.origins(isEnabled: false, managed: managed, modes: modes).isEmpty)
        #expect(VoiceNetworkPolicy.allowed(isEnabled: true, managed: ManagedSettings(voiceDisabled: true), modes: modes).isEmpty)
        let http = VoiceHTTP()
        VoiceNetworkPolicy.apply(isEnabled: true, managed: managed, modes: modes, to: http)
        #expect(http.allowedOrigins.contains("https://api.openai.com:443"))
        VoiceNetworkPolicy.apply(isEnabled: false, managed: managed, modes: modes, to: http)
        #expect(http.allowedOrigins.isEmpty && http.allowed.isEmpty)
    }
}
