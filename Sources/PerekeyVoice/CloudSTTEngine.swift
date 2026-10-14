// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore

/// Speech recognition by an OpenAI-compatible server (`audio/transcriptions`):
/// OpenAI, Groq. Nothing to load; the audio of a dictation goes out as a WAV
/// file through `OpenAICompatibleClient`, and only to an origin `VoiceHTTP`
/// allows.
public actor CloudSTTEngine: SpeechEngine {
    /// Where to send and with what key, read for every dictation: the user
    /// may change the address or the key between two.
    public struct Target: Sendable {
        public var address: EndpointAddress
        public var key: String?

        public init(address: EndpointAddress, key: String?) {
            self.address = address
            self.key = key
        }
    }

    public enum Failure: Error, Hashable, Sendable {
        /// The endpoint is gone, has no usable address, or needs a key.
        case unavailable
    }

    public nonisolated let id: String
    private let model: String
    private let client: OpenAICompatibleClient
    private let target: @Sendable () async -> Target?

    public init(model: CloudSpeechModel, client: OpenAICompatibleClient,
                target: @escaping @Sendable () async -> Target?)
    {
        id = model.id
        self.model = model.model
        self.client = client
        self.target = target
    }

    public func prepare() async throws {}
    public func unload() async {}

    public func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        try await transcribe(audio, prompt: nil)
    }

    /// The prompt, the words of the user's dictionary, goes in the request's
    /// `prompt` field: the server's Whisper spells them so.
    public func transcribe(_ audio: AudioBuffer16k, prompt: String?) async throws -> Transcript {
        guard let target = await target() else { throw Failure.unavailable }
        let text = try await client.transcribe(audio, model: model, address: target.address, key: target.key,
                                               prompt: prompt)
        return Transcript(text: text)
    }
}
