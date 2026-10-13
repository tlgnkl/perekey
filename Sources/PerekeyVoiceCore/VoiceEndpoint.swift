// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// An OpenAI-compatible server: a cloud provider by the user's key, or a
/// local one (Ollama, LM Studio). Keys live in the Keychain by `id`, never here.
public struct VoiceEndpoint: Codable, Hashable, Sendable, Identifiable {
    /// The preset's raw value, or "custom-…" for an address the user added.
    public var id: String
    public var name: String
    /// The base address, up to and including the API version ("https://api.openai.com/v1").
    public var address: String

    public init(id: String, name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }

    public init(_ preset: Preset) {
        self.init(id: preset.rawValue, name: preset.name, address: preset.address)
    }

    public var preset: Preset? { Preset(rawValue: id) }

    /// The parsed `address`; nil when it is not a usable one.
    public var endpointAddress: EndpointAddress? { EndpointAddress(address) }

    /// Whether requests need a key: every preset in the cloud. A custom
    /// address takes a key when the user gives one.
    public var needsKey: Bool { preset?.needsKey ?? false }

    public enum Preset: String, CaseIterable, Sendable {
        case openAI = "openai"
        case groq
        case openRouter = "openrouter"
        case mistral
        case gemini
        case ollama
        case lmStudio = "lmstudio"

        public var name: String {
            switch self {
            case .openAI: "OpenAI"
            case .groq: "Groq"
            case .openRouter: "OpenRouter"
            case .mistral: "Mistral"
            case .gemini: "Gemini"
            case .ollama: "Ollama"
            case .lmStudio: "LM Studio"
            }
        }

        public var address: String {
            switch self {
            case .openAI: "https://api.openai.com/v1"
            case .groq: "https://api.groq.com/openai/v1"
            case .openRouter: "https://openrouter.ai/api/v1"
            case .mistral: "https://api.mistral.ai/v1"
            // Gemini's OpenAI-compatible address.
            case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
            case .ollama: "http://localhost:11434/v1"
            case .lmStudio: "http://localhost:1234/v1"
            }
        }

        public var needsKey: Bool {
            switch self {
            case .ollama, .lmStudio: false
            default: true
            }
        }

        /// A language model to start a mode with.
        public var suggestedModel: String {
            switch self {
            case .openAI: "gpt-4o-mini"
            case .groq: "llama-3.3-70b-versatile"
            case .openRouter: "openai/gpt-4o-mini"
            case .mistral: "mistral-small-latest"
            case .gemini: "gemini-2.5-flash"
            case .ollama: "qwen2.5:7b"
            case .lmStudio: ""
            }
        }
    }
}

/// A server address as voice may use it: `https` anywhere, `http` only on
/// this Mac or in the local network. Pure parsing, no Foundation.
public struct EndpointAddress: Hashable, Sendable {
    public enum Scheme: String, Sendable {
        case http, https
    }

    public enum Reach: Hashable, Sendable {
        /// This Mac: `localhost`, 127.0.0.0/8, ::1.
        case loopback
        /// A private address or a `.local` name: another machine nearby.
        case localNetwork
        case internet
    }

    public let scheme: Scheme
    /// Lowercased, IPv6 without brackets.
    public let host: String
    public let port: Int
    /// "/v1", never ending in "/"; empty for none.
    public let path: String

    /// Nil for an address that is not http(s), has no host, has credentials,
    /// a query or a fragment, or is plain `http` to the internet.
    public init?(_ string: String) {
        var text = Substring(string)
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        guard let colon = text.firstIndex(of: ":"), text[colon...].hasPrefix("://"),
              let scheme = Scheme(rawValue: text[..<colon].lowercased())
        else { return nil }
        text = text[text.index(colon, offsetBy: 3)...]
        let authorityEnd = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let authority = text[..<authorityEnd]
        var rest = text[authorityEnd...]
        guard !authority.contains("@"), !rest.contains("?"), !rest.contains("#") else { return nil }
        var host: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        } else {
            host = authority
            if let colon = authority.lastIndex(of: ":") {
                host = authority[..<colon]
                portText = authority[authority.index(after: colon)...]
            }
            guard SiteHost.isValid(String(host).lowercased()) else { return nil }
        }
        if let portText {
            guard let port = Int(portText), (1...65535).contains(port) else { return nil }
            self.port = port
        } else {
            port = scheme == .https ? 443 : 80
        }
        while rest.hasSuffix("/") { rest.removeLast() }
        self.scheme = scheme
        self.host = host.lowercased()
        path = String(rest)
        if scheme == .http, reach == .internet { return nil }
    }

    /// "scheme://host:port": what consent and the network gate are keyed by.
    /// Another path on the same server is the same origin.
    public var origin: String { Self.origin(scheme: scheme.rawValue, host: host, port: port) }

    public static func origin(scheme: String, host: String, port: Int) -> String {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return "\(scheme.lowercased())://\(host):\(port)"
    }

    /// The base address with `path` after it ("/chat/completions").
    public func url(_ suffix: String) -> String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == .https ? 443 : 80
        let shownPort = port == defaultPort ? "" : ":\(port)"
        return "\(scheme.rawValue)://\(shownHost)\(shownPort)\(path)\(suffix)"
    }

    /// The host as the consent window and the HUD name it, with a port that is not the default.
    public var displayHost: String {
        let defaultPort = scheme == .https ? 443 : 80
        return port == defaultPort ? host : "\(host):\(port)"
    }

    public var reach: Reach {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return .loopback }
        if let octets = Self.ipv4(host) {
            switch (octets[0], octets[1]) {
            case (127, _): return .loopback
            case (10, _), (192, 168), (169, 254): return .localNetwork
            case (172, 16...31): return .localNetwork
            default: return .internet
            }
        }
        if host.contains(":") {
            // fc00::/7 unique local, fe80::/10 link-local.
            let first = host.split(separator: ":").first.map { $0.lowercased() } ?? ""
            if first.count == 4, first.hasPrefix("fc") || first.hasPrefix("fd") { return .localNetwork }
            if first.hasPrefix("fe8") || first.hasPrefix("fe9") || first.hasPrefix("fea") || first.hasPrefix("feb") {
                return .localNetwork
            }
            return .internet
        }
        if host.hasSuffix(".local") || !host.contains(".") { return .localNetwork }
        return .internet
    }

    /// Whether what goes there stays on this Mac. Anything else leaves it,
    /// and needs consent.
    public var isOnThisMac: Bool { reach == .loopback }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }.filter { (0...255).contains($0) }
        return octets.count == 4 ? octets : nil
    }
}

/// A speech model in the cloud, by its id "cloud:<endpoint>:<model>".
public struct CloudSpeechModel: Hashable, Sendable {
    public var endpoint: String
    public var model: String

    public init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }

    public init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "cloud", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        endpoint = String(parts[1])
        model = String(parts[2])
    }

    public var id: String { "cloud:\(endpoint):\(model)" }

    /// The models of `audio/transcriptions` the presets offer.
    public static let known: [CloudSpeechModel] = [
        CloudSpeechModel(endpoint: VoiceEndpoint.Preset.openAI.rawValue, model: "gpt-4o-mini-transcribe"),
        CloudSpeechModel(endpoint: VoiceEndpoint.Preset.openAI.rawValue, model: "gpt-4o-transcribe"),
        CloudSpeechModel(endpoint: VoiceEndpoint.Preset.groq.rawValue, model: "whisper-large-v3-turbo"),
    ]

    public var displayName: String {
        switch model {
        case "gpt-4o-mini-transcribe": "GPT-4o mini Transcribe"
        case "gpt-4o-transcribe": "GPT-4o Transcribe"
        case "whisper-large-v3-turbo": "Whisper large-v3 turbo"
        default: model
        }
    }
}
