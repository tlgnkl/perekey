// SPDX-License-Identifier: GPL-3.0-or-later

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
    let model: String
    let address: EndpointAddress
    let key: String?

    public init(model: String, address: EndpointAddress, key: String?, http: VoiceHTTP = .shared) {
        self.model = model
        self.address = address
        self.key = key
        client = OpenAICompatibleClient(
            http: http, timeout: address.reach == .internet ? Self.cloudTimeout : Self.localTimeout)
    }

    /// A server on the internet takes a long transcript in fewer pieces.
    public var budget: SummaryBudget { address.reach == .internet ? .cloud : .local }

    /// A request the gate stopped is one without consent: voice off and the
    /// profile are checked before the run starts.
    public func complete(_ messages: [ChatMessage]) async throws -> String {
        do {
            return try await client.complete(messages, model: model, address: address, key: key,
                                             purpose: .conversationLanguageModel)
        } catch OpenAICompatibleClient.Failure.blocked {
            throw SummaryFailure.needsConsent
        }
    }
}
