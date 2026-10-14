// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore

/// A language model of the modes' servers for «Конспект» and «Протокол
/// встречи»: chat completions through `OpenAICompatibleClient`, sent as
/// `conversationLanguageModel`, which `VoiceHTTP` lets out only to this Mac
/// and to servers the user agreed to send transcripts to.
public struct SummaryServer: SummaryLanguageModel {
    /// The wait for one answer. A local model reads a few pages and writes
    /// a page; on a cold start it loads first.
    public static let localTimeout: Duration = .seconds(300)
    public static let cloudTimeout: Duration = .seconds(120)

    let client: OpenAICompatibleClient
    let http: VoiceHTTP
    let model: String
    let address: EndpointAddress
    let key: String?

    public init(model: String, address: EndpointAddress, key: String?, http: VoiceHTTP = .shared) {
        self.model = model
        self.address = address
        self.key = key
        self.http = http
        client = OpenAICompatibleClient(
            http: http, timeout: address.reach == .internet ? Self.cloudTimeout : Self.localTimeout)
    }

    /// A server on the internet takes a long transcript in fewer pieces; one
    /// nearby, the smallest window, unless it says its own.
    public var budget: SummaryBudget { address.reach == .internet ? .cloud : .local }

    /// The gate's refusal is `blocked`: the window tells voice off, the
    /// profile and consent taken back apart. A prompt the server says is too
    /// long for the model is `tooLongForModel`.
    public func reply(to messages: [ChatMessage]) async throws -> SummaryReply {
        do {
            let answer = try await client.chat(messages, model: model, address: address, key: key,
                                               purpose: .conversationLanguageModel)
            return SummaryReply(text: answer.text, promptTokens: answer.promptTokens)
        } catch OpenAICompatibleClient.Failure.blocked {
            throw SummaryFailure.blocked
        } catch let OpenAICompatibleClient.Failure.server(status, message) where Self.isOverflow(status, message) {
            throw SummaryFailure.tooLongForModel
        }
    }

    /// "context_length_exceeded", "maximum context length", "too many tokens": an
    /// OpenAI-style 400, or 413.
    static func isOverflow(_ status: Int, _ message: String?) -> Bool {
        if status == 413 { return true }
        guard status == 400, let message = message?.lowercased() else { return false }
        return ["context length", "context_length", "context window", "too many tokens", "too long", "maximum context"]
            .contains { message.contains($0) }
    }

    /// The window a server nearby loads the model with: Ollama's `num_ctx`
    /// (`/api/show`), or LM Studio's loaded context (`/api/v0/models`). Nil
    /// for the cloud, and when the server does not say.
    public func contextWindow() async -> Int? {
        guard address.reach != .internet else { return nil }
        if let window = await ollamaWindow() { return window }
        return await lmStudioWindow()
    }

    private func ollamaWindow() async -> Int? {
        struct Show: Decodable {
            let parameters: String?
        }
        guard let url = URL(string: root("/api/show")) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["model": model])
        request.timeoutInterval = 10
        guard let show: Show = await fetch(request) else { return nil }
        return Self.numContext(in: show.parameters ?? "")
    }

    private func lmStudioWindow() async -> Int? {
        struct Model: Decodable {
            let loaded_context_length: Int?
        }
        let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: root("/api/v0/models/\(id)")) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let found: Model? = await fetch(request)
        return found?.loaded_context_length
    }

    /// `num_ctx 8192` among Ollama's parameters.
    static func numContext(in parameters: String) -> Int? {
        for line in parameters.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[0] == "num_ctx", let value = Int(parts[1]), value > 0 { return value }
        }
        return nil
    }

    /// The server's root: the address without its API path ("/v1").
    private func root(_ path: String) -> String {
        let base = address.url("")
        return String(base.dropLast(address.path.count)) + path
    }

    private func fetch<Value: Decodable>(_ request: URLRequest) async -> Value? {
        guard let (data, response) = try? await http.data(for: request, purpose: .conversationLanguageModel),
              response.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
