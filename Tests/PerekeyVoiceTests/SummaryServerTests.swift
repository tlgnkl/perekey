// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

struct SummaryServerTests {
    /// A fake server open for summaries only.
    static func server(_ handler: @escaping TestServer.Handler) async throws -> (FakeOpenAI, SummaryServer) {
        let fake = try await FakeOpenAI(handler)
        fake.http.allowed = [.conversationLanguageModel]
        fake.http.allowedOrigins = [.conversationLanguageModel: [fake.address.origin]]
        return (fake, SummaryServer(model: "qwen2.5:7b", address: fake.address, key: nil, http: fake.http))
    }

    /// Ollama names the window in `num_ctx` of `/api/show`; the answer's `usage` is read.
    @Test func theWindowAndTheUsageComeFromTheServer() async throws {
        let (fake, server) = try await Self.server { request, _ in
            switch request.path {
            case "/api/show":
                FakeOpenAI.json(["parameters": "stop \"<|im_end|>\"\nnum_ctx 8192"])
            default:
                FakeOpenAI.json(["choices": [["message": ["content": "Итоги"]]], "usage": ["prompt_tokens": 1234]])
            }
        }
        #expect(await server.contextWindow() == 8192)
        let show = try #require(fake.server.requests.first)
        #expect(show.method == "POST" && FakeOpenAI.body(show)["model"] as? String == "qwen2.5:7b")
        let reply = try await server.reply(to: [ChatMessage(role: .user, content: "x")])
        #expect(reply == SummaryReply(text: "Итоги", promptTokens: 1234))
    }

    /// A server that names no window leaves the smallest one.
    @Test func noWindowSaidIsNone() async throws {
        let (fake, server) = try await Self.server { _, _ in FakeOpenAI.json(["error": ["message": "not found"]], status: 404) }
        #expect(await server.contextWindow() == nil)
        #expect(fake.server.requests.count == 2, "Ollama, then LM Studio")
        #expect(server.budget == .local)
        #expect(SummaryServer.numContext(in: "num_ctx 4096") == 4096)
        #expect(SummaryServer.numContext(in: "temperature 0.7\nnum_ctx x") == nil)
    }

    /// LM Studio says the context it loaded the model with.
    @Test func lmStudioWindow() async throws {
        let (fake, server) = try await Self.server { request, _ in
            request.path.hasPrefix("/api/v0/models/") ? FakeOpenAI.json(["loaded_context_length": 16384])
                : FakeOpenAI.json([:], status: 404)
        }
        #expect(await server.contextWindow() == 16384)
        #expect(fake.server.requests.last?.path.hasPrefix("/api/v0/models/qwen2.5") == true)
    }

    /// A 400 about the context is "does not fit", not "the model failed".
    @Test func anOverflowIsSaidSo() async throws {
        let (fake, server) = try await Self.server { _, _ in
            FakeOpenAI.json(["error": ["message": "This model's maximum context length is 8192 tokens", "code": "context_length_exceeded"]],
                            status: 400)
        }
        await #expect(throws: SummaryFailure.tooLongForModel) {
            try await server.reply(to: [ChatMessage(role: .user, content: "x")])
        }
        #expect(fake.server.requests.count == 1)
        #expect(SummaryServer.isOverflow(413, nil))
        #expect(!SummaryServer.isOverflow(400, "invalid model"))
        #expect(!SummaryServer.isOverflow(500, "context length"))
    }

    /// The cloud is never asked for a window.
    @Test func theCloudIsNotAskedForAWindow() async {
        let http = VoiceHTTP(allowed: [.conversationLanguageModel])
        let server = SummaryServer(model: "gpt-4o-mini", address: EndpointAddress("https://api.openai.com/v1")!, key: nil, http: http)
        #expect(await server.contextWindow() == nil)
        #expect(http.requests.isEmpty)
        #expect(server.budget == .cloud)
    }
}
