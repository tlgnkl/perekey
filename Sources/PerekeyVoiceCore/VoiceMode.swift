// SPDX-License-Identifier: GPL-3.0-or-later

/// A dictation mode: what happens to the text between recognition and the
/// paste, and where the mode turns on by itself. `ModeResolver` picks it by
/// the site, then the app in front.
///
/// Decoding tolerates missing and unreadable keys: each falls back to its
/// default. "Paste and Enter" is never kept for a mode with a language model
/// or a single-line mode: a model may write a command, and Enter would run it.
public struct VoiceMode: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A speech model: an id of `ModelCatalog` or of `CloudSpeechModel`; nil
    /// takes the one of the voice settings.
    public var model: String?
    public var rules: ModeTextRules {
        didSet { clampOutput() }
    }

    /// The language model step; nil pastes the text as recognized.
    public var refine: RefineConfig? {
        didSet { clampOutput() }
    }

    /// What the language model may see besides the dictation.
    public var context: ModeContext
    public var output: ModeOutput {
        didSet { clampOutput() }
    }

    /// Apps and sites where the mode turns on by itself.
    public var bindings: [ModeBinding]

    public init(id: String, name: String, model: String? = nil, rules: ModeTextRules = ModeTextRules(),
                refine: RefineConfig? = nil, context: ModeContext = ModeContext(), output: ModeOutput = .paste,
                bindings: [ModeBinding] = [])
    {
        self.id = id
        self.name = name
        self.model = model
        self.rules = rules
        self.refine = refine
        self.context = context
        self.output = output
        self.bindings = bindings
        clampOutput()
    }

    /// Whether "Paste and Enter" may be chosen.
    public var allowsEnter: Bool { refine == nil && !rules.singleLine }

    private mutating func clampOutput() {
        if output == .pasteAndEnter, !allowsEnter { output = .paste }
    }

    /// What leaves the Mac for `endpoint` in a dictation of this mode: the
    /// audio for a cloud speech model, the text and the chosen context for
    /// the language model. Empty when the mode does not use it.
    public func data(for endpoint: String) -> ModeData {
        var data: ModeData = []
        if let model, CloudSpeechModel(id: model)?.endpoint == endpoint { data.insert(.audio) }
        if let refine, refine.endpoint == endpoint {
            data.insert(.text)
            if context.selection { data.insert(.selection) }
            if context.app { data.insert(.app) }
            if context.site { data.insert(.site) }
        }
        return data
    }

    /// The endpoints the mode sends to.
    public var endpoints: [String] {
        var ids: [String] = []
        if let model, let cloud = CloudSpeechModel(id: model) { ids.append(cloud.endpoint) }
        if let refine, !ids.contains(refine.endpoint) { ids.append(refine.endpoint) }
        return ids
    }
}

/// The text rules of a mode, over those of the voice settings.
public struct ModeTextRules: Codable, Hashable, Sendable {
    /// Line breaks become spaces, and Enter is never pressed: for terminals
    /// and code, where a line break runs what was typed.
    public var singleLine: Bool
    /// Filler words: nil follows the voice settings.
    public var removesFillers: Bool?

    public init(singleLine: Bool = false, removesFillers: Bool? = nil) {
        self.singleLine = singleLine
        self.removesFillers = removesFillers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        singleLine = (try? container.decodeIfPresent(Bool.self, forKey: .singleLine)) ?? false
        removesFillers = (try? container.decodeIfPresent(Bool.self, forKey: .removesFillers)) ?? nil
    }
}

/// The language model step of a mode.
public struct RefineConfig: Codable, Hashable, Sendable {
    /// `VoiceEndpoint.id`.
    public var endpoint: String
    /// The model name the endpoint knows ("gpt-4o-mini", "qwen2.5:7b").
    public var model: String
    /// What to do with the text. `{{text}}` and `{{selection}}` name the
    /// delimited blocks; `{{app}}` and `{{site}}` are replaced with the app's
    /// name and the site's host when the mode sends them.
    public var prompt: String

    public init(endpoint: String, model: String, prompt: String) {
        self.endpoint = endpoint
        self.model = model
        self.prompt = prompt
    }
}

/// What the language model may see besides the dictation.
public struct ModeContext: Codable, Hashable, Sendable {
    /// The text selected in the field when the dictation started.
    public var selection: Bool
    /// The name of the app in front ("Telegram").
    public var app: Bool
    /// The host of the page in front, never the whole address.
    public var site: Bool

    public init(selection: Bool = false, app: Bool = false, site: Bool = false) {
        self.selection = selection
        self.app = app
        self.site = site
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selection = (try? container.decodeIfPresent(Bool.self, forKey: .selection)) ?? false
        app = (try? container.decodeIfPresent(Bool.self, forKey: .app)) ?? false
        site = (try? container.decodeIfPresent(Bool.self, forKey: .site)) ?? false
    }
}

/// Where the text goes.
public enum ModeOutput: String, Codable, Hashable, Sendable, CaseIterable {
    case paste
    /// To the pasteboard only.
    case copy
    /// Paste, then press Return: send a message. Not with a language model.
    case pasteAndEnter
}

/// An app or a site where a mode turns on by itself.
public enum ModeBinding: Hashable, Sendable {
    /// A bundle ID; one ending in "." covers every ID it begins ("com.jetbrains.").
    case app(String)
    /// A normalized host; it covers its subdomains.
    case site(String)

    public func matches(bundleID: String) -> Bool {
        guard case let .app(id) = self else { return false }
        return id.hasSuffix(".") ? bundleID.hasPrefix(id) : bundleID == id
    }
}

extension ModeBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case app, site
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let app = try container.decodeIfPresent(String.self, forKey: .app) {
            self = .app(app)
        } else {
            self = try .site(container.decode(String.self, forKey: .site))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .app(id): try container.encode(id, forKey: .app)
        case let .site(host): try container.encode(host, forKey: .site)
        }
    }
}

/// What a dictation sends to an endpoint. Consent is given for a set.
public struct ModeData: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let audio = ModeData(rawValue: 1 << 0)
    public static let text = ModeData(rawValue: 1 << 1)
    public static let selection = ModeData(rawValue: 1 << 2)
    public static let app = ModeData(rawValue: 1 << 3)
    public static let site = ModeData(rawValue: 1 << 4)

    /// In the order the consent window names them.
    public static let all: [ModeData] = [.audio, .text, .selection, .app, .site]
}

extension VoiceMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, model, rules, refine, context, output, bindings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        self.init(
            id: id,
            name: (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id,
            model: (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil,
            rules: (try? container.decodeIfPresent(ModeTextRules.self, forKey: .rules)) ?? ModeTextRules(),
            refine: (try? container.decodeIfPresent(RefineConfig.self, forKey: .refine)) ?? nil,
            context: (try? container.decodeIfPresent(ModeContext.self, forKey: .context)) ?? ModeContext(),
            output: (try? container.decodeIfPresent(ModeOutput.self, forKey: .output)) ?? .paste,
            // One unreadable binding does not cost the others.
            bindings: ((try? container.decodeIfPresent([Lenient<ModeBinding>].self, forKey: .bindings)) ?? nil)?
                .compactMap(\.value) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(rules, forKey: .rules)
        try container.encodeIfPresent(refine, forKey: .refine)
        try container.encode(context, forKey: .context)
        try container.encode(output, forKey: .output)
        try container.encode(bindings, forKey: .bindings)
    }
}

/// An element of a list that decodes to nil instead of failing the list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
