// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore

/// One client for every OpenAI-compatible server: OpenAI, Groq, OpenRouter,
/// Mistral, Gemini, Ollama, LM Studio, or an address the user typed. Chat
/// completions for the modes' language models, audio transcriptions for
/// cloud speech. Everything goes through `VoiceHTTP`, which lets a request
/// out only to an origin the app allowed.
///
/// The key goes in the `Authorization` header and nowhere else; errors never
/// carry it, nor the text sent.
public struct OpenAICompatibleClient: Sendable {
    public enum Failure: Error, Hashable, Sendable {
        /// Not https, and not on this Mac or in the local network.
        case badAddress
        /// `VoiceHTTP` did not let the request out: voice off, cloud off by
        /// the profile, or no consent for the origin.
        case blocked
        /// 401 or 403: the key is wrong, missing or revoked.
        case unauthorized
        /// 429.
        case rateLimited
        /// 404: often a model name the server does not know.
        case notFound
        /// Another status, with the server's message if it gave one.
        case server(status: Int, message: String?)
        /// The answer is not what the API returns.
        case badResponse
        case timedOut
        case offline
    }

    let http: VoiceHTTP
    /// The longest wait for a whole answer.
    let timeout: Duration

    public init(http: VoiceHTTP = .shared, timeout: Duration = .seconds(30)) {
        self.http = http
        self.timeout = timeout
    }

    // MARK: Chat

    /// The text of the first choice of a chat completion.
    public func complete(_ messages: [ChatMessage], model: String, address: EndpointAddress, key: String?,
                         temperature: Double = 0.2) async throws -> String
    {
        struct Body: Encodable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Double
            let stream = false
        }
        struct Answer: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }

                let message: Message
            }

            let choices: [Choice]
        }
        var request = try request(address, "/chat/completions", key: key)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, temperature: temperature))
        let data = try await send(request, purpose: .cloudLanguageModel)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let content = answer.choices.first?.message.content
        else { throw Failure.badResponse }
        return content
    }

    // MARK: Transcription

    /// The text of `audio`, sent as a 16-bit WAV file.
    public func transcribe(_ audio: AudioBuffer16k, model: String, address: EndpointAddress, key: String?,
                           language: String? = nil) async throws -> String
    {
        struct Answer: Decodable {
            let text: String
        }
        let boundary = "perekey-\(UUID().uuidString)"
        var request = try request(address, "/audio/transcriptions", key: key)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var form = MultipartForm(boundary: boundary)
        form.field("model", model)
        form.field("response_format", "json")
        if let language { form.field("language", language) }
        form.file("file", name: "dictation.wav", type: "audio/wav", data: WAV.encode(audio))
        request.httpBody = form.finish()
        let data = try await send(request, purpose: .cloudSpeech)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw Failure.badResponse }
        return answer.text
    }

    // MARK: Requests

    private func request(_ address: EndpointAddress, _ path: String, key: String?) throws -> URLRequest {
        guard let url = URL(string: address.url(path)) else { throw Failure.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The body of a 2xx answer, within `timeout`.
    private func send(_ request: URLRequest, purpose: VoiceHTTP.Purpose) async throws -> Data {
        let http = self.http
        let timeout = self.timeout
        let (data, response) = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse)?.self) { group in
            group.addTask { try await http.data(for: request, purpose: purpose) }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next(), let answer = first else { throw Failure.timedOut }
                return answer
            } catch let failure as VoiceHTTP.Failure {
                switch failure {
                case .blocked: throw Failure.blocked
                case .offline: throw Failure.offline
                case .redirectRefused: throw Failure.badResponse
                }
            } catch let error as URLError where error.code == .timedOut {
                throw Failure.timedOut
            } catch let error as URLError where [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                                                 .networkConnectionLost].contains(error.code)
            {
                throw Failure.offline
            }
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw Failure.unauthorized
        case 404: throw Failure.notFound
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status: response.statusCode, message: Self.message(in: data))
        }
    }

    /// `error.message` of an OpenAI-style error body, one line, at most 200 characters.
    static func message(in data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable {
                let message: String?
            }

            let error: Inner?
        }
        guard let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message else { return nil }
        return String(message.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
    }
}

/// A `multipart/form-data` body.
struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func field(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, name fileName: String, type: String, data: Data) {
        body.append(Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(type)\r\n\r\n"
                .utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}

/// 16 kHz mono audio as a 16-bit PCM WAV file.
enum WAV {
    static func encode(_ audio: AudioBuffer16k) -> Data {
        let rate = UInt32(VoiceCore.sampleRate)
        let samples = audio.samples
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let payload = UInt32(samples.count * 2)
        data.append(Data("RIFF".utf8))
        append(36 + payload)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(rate)
        append(rate * 2) // bytes per second
        append(UInt16(2)) // block align
        append(UInt16(16)) // bits per sample
        data.append(Data("data".utf8))
        append(payload)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}
