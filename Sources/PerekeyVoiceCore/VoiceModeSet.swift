// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The modes, the endpoints and the consents, as stored in their own file
/// beside the voice settings (`VoiceModesFile`).
///
/// Like `VoiceSettings`, a file of a higher `schemaVersion` is read but not
/// acted on: its modes are shown, every dictation pastes as it was
/// recognized, no request leaves, and the file is never overwritten.
///
/// A value this version cannot read at its own `schemaVersion` falls back to
/// its default for dictation, and marks the file (`hasUnreadableContent`):
/// it is shown, never written, so nothing of it is lost by a save.
public struct VoiceModeSet: Hashable, Sendable {
    /// Raise it only when an older Perekey must not act on the file at all,
    /// and whenever a value gets a new case: a new `ModeOutput`, a new kind of
    /// `ModeBinding`, a new `ModeData` the consent must name. An older version
    /// would otherwise take the new value for its default and act on it.
    public static let schemaVersion = 1

    public var modes: [VoiceMode]
    /// The mode where no binding applies.
    public var defaultModeID: String
    /// A mode the user picked in the menu; it holds everywhere until "Auto".
    public var pinnedModeID: String?
    public var endpoints: [VoiceEndpoint]
    /// What the user agreed to send, by `EndpointAddress.origin`.
    public var consents: [String: ModeData]

    /// The built-in modes (`BuiltInMode` ids) this file has seen: a newer
    /// version adds those it does not list, never one the user deleted.
    public var builtIns: [String]

    /// The `schemaVersion` of the file read, if it is higher than this version's.
    public private(set) var newerSchemaVersion: Int?
    /// The file has a value this version could not read.
    public private(set) var hasUnreadableContent = false

    /// Shown, not changed: a newer file, or one with values this version cannot read.
    public var isReadOnly: Bool { newerSchemaVersion != nil || hasUnreadableContent }

    public init(modes: [VoiceMode], defaultModeID: String, pinnedModeID: String? = nil,
                endpoints: [VoiceEndpoint] = VoiceEndpoint.Preset.allCases.map(VoiceEndpoint.init),
                consents: [String: ModeData] = [:], builtIns: [String] = BuiltInMode.allCases.map(\.rawValue))
    {
        self.builtIns = builtIns
        self.modes = modes
        self.defaultModeID = defaultModeID
        self.pinnedModeID = pinnedModeID
        self.endpoints = endpoints
        self.consents = consents
    }

    public func mode(_ id: String?) -> VoiceMode? {
        guard let id else { return nil }
        return modes.first { $0.id == id }
    }

    public func endpoint(_ id: String?) -> VoiceEndpoint? {
        guard let id else { return nil }
        return endpoints.first { $0.id == id }
    }

    /// The mode used where nothing else applies; the first one if the id is lost.
    public var defaultMode: VoiceMode? { mode(defaultModeID) ?? modes.first }

    // MARK: Consent

    /// What `mode` would send to `endpoint` that the user has not agreed to;
    /// empty when nothing is missing or the endpoint is on this Mac.
    public func missingConsent(_ mode: VoiceMode, endpoint id: String) -> ModeData {
        guard let address = endpoint(id)?.endpointAddress, !address.isOnThisMac else { return [] }
        return mode.data(for: id).subtracting(consents[address.origin] ?? [])
    }

    /// Records consent to send `data` to `endpoint`, over what was agreed before.
    public mutating func consent(_ data: ModeData, endpoint id: String) {
        guard let origin = endpoint(id)?.endpointAddress?.origin else { return }
        consents[origin, default: []].formUnion(data)
    }

    /// Origins a request carrying `data` may go to: those on this Mac, and
    /// those the user agreed to send it to. Only this Mac's when a profile
    /// forbids the cloud. Cloud speech sends `.audio`, a language model `.text`.
    public func reachableOrigins(sending data: ModeData, cloudDisabled: Bool) -> Set<String> {
        guard newerSchemaVersion == nil else { return [] }
        var origins = Set<String>()
        for endpoint in endpoints {
            guard let address = endpoint.endpointAddress else { continue }
            if address.isOnThisMac || (!cloudDisabled && (consents[address.origin] ?? []).isSuperset(of: data)) {
                origins.insert(address.origin)
            }
        }
        return origins
    }

    /// Whether a recording of a conversation may go to `endpoint` for its
    /// transcript: an endpoint on this Mac, or one the user agreed to send
    /// `conversationAudio` to; never while a profile forbids the cloud.
    public func mayUploadConversation(to id: String, cloudDisabled: Bool) -> Bool {
        guard newerSchemaVersion == nil, let address = endpoint(id)?.endpointAddress else { return false }
        if address.isOnThisMac { return true }
        return !cloudDisabled && (consents[address.origin] ?? []).contains(.conversationAudio)
    }

    /// Takes back every consent given for `endpoint`'s origin.
    public mutating func revokeConsent(endpoint id: String) {
        guard let origin = endpoint(id)?.endpointAddress?.origin else { return }
        consents[origin] = nil
    }

    // MARK: Editing

    /// Adds a mode with a fresh id and returns it.
    @discardableResult
    public mutating func addMode(name: String) -> VoiceMode {
        var number = modes.count + 1
        while modes.contains(where: { $0.id == "mode-\(number)" }) { number += 1 }
        let mode = VoiceMode(id: "mode-\(number)", name: name)
        modes.append(mode)
        return mode
    }

    /// Removes a mode; the default and the pinned one move off it.
    public mutating func removeMode(_ id: String) {
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == id }
        if defaultModeID == id { defaultModeID = modes[0].id }
        if pinnedModeID == id { pinnedModeID = nil }
    }

    /// Adds a custom address and returns its endpoint.
    @discardableResult
    public mutating func addEndpoint(name: String, address: String) -> VoiceEndpoint {
        var number = 1
        while endpoints.contains(where: { $0.id == "custom-\(number)" }) { number += 1 }
        let endpoint = VoiceEndpoint(id: "custom-\(number)", name: name, address: address)
        endpoints.append(endpoint)
        return endpoint
    }

    /// Binds `binding` to `mode`, taking it off any other mode: an app or a
    /// site turns on one mode.
    public mutating func bind(_ binding: ModeBinding, to mode: String) {
        for index in modes.indices {
            modes[index].bindings.removeAll { $0 == binding }
            if modes[index].id == mode { modes[index].bindings.append(binding) }
        }
    }
}

// MARK: - Codable

extension VoiceModeSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modes, defaultModeID, pinnedModeID, endpoints, consents, builtIns
    }

    /// Missing or unreadable keys fall back to the defaults; modes and
    /// endpoints that cannot be read are dropped one by one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceModeSet.defaults()
        let modes = ((try? container.decodeIfPresent([Lenient<VoiceMode>].self, forKey: .modes)) ?? nil)?
            .compactMap(\.value) ?? []
        self.modes = modes.isEmpty ? defaults.modes : modes
        defaultModeID = (try? container.decodeIfPresent(String.self, forKey: .defaultModeID)) ?? nil
            ?? defaults.defaultModeID
        pinnedModeID = (try? container.decodeIfPresent(String.self, forKey: .pinnedModeID)) ?? nil
        var endpoints = ((try? container.decodeIfPresent([Lenient<VoiceEndpoint>].self, forKey: .endpoints)) ?? nil)?
            .compactMap(\.value) ?? []
        // Presets this version added since the file was written.
        for preset in VoiceEndpoint.Preset.allCases where !endpoints.contains(where: { $0.id == preset.rawValue }) {
            endpoints.append(VoiceEndpoint(preset))
        }
        self.endpoints = endpoints
        consents = ((try? container.decodeIfPresent([String: ModeData].self, forKey: .consents)) ?? nil) ?? [:]
        // A file without the key had every built-in mode of this version.
        builtIns = ((try? container.decodeIfPresent([String].self, forKey: .builtIns)) ?? nil)
            ?? BuiltInMode.allCases.map(\.rawValue)
        hasUnreadableContent = (try? StrictModeSet(from: decoder)) == nil
        if let version = try? container.decodeIfPresent(Int.self, forKey: .schemaVersion),
           version > Self.schemaVersion
        {
            newerSchemaVersion = version
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(modes, forKey: .modes)
        try container.encode(defaultModeID, forKey: .defaultModeID)
        try container.encodeIfPresent(pinnedModeID, forKey: .pinnedModeID)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(consents, forKey: .consents)
        try container.encode(builtIns, forKey: .builtIns)
    }
}

/// The file's layout, read with no fallback: whatever fails here is a value
/// this version cannot read.
private struct StrictModeSet: Decodable {
    struct Mode: Decodable {
        struct Rules: Decodable {
            let singleLine: Bool?
            let removesFillers: Bool?
        }

        struct Context: Decodable {
            let selection: Bool?
            let app: Bool?
            let site: Bool?
        }

        let id: String
        let name: String?
        let model: String?
        let rules: Rules?
        let refine: RefineConfig?
        let context: Context?
        let output: ModeOutput?
        let bindings: [ModeBinding]?
    }

    let schemaVersion: Int?
    let modes: [Mode]?
    let defaultModeID: String?
    let pinnedModeID: String?
    let endpoints: [VoiceEndpoint]?
    let consents: [String: ModeData]?
    let builtIns: [String]?
}

// MARK: - Built-in modes over time

extension VoiceModeSet {
    /// Adds the built-in modes of `defaults` this file has not seen yet.
    public mutating func adoptNewBuiltIns(from defaults: VoiceModeSet) {
        for mode in defaults.modes where BuiltInMode(rawValue: mode.id) != nil && !builtIns.contains(mode.id) {
            builtIns.append(mode.id)
            if self.mode(mode.id) == nil { modes.append(mode) }
        }
    }

    /// The built-in modes of `defaults` that were deleted.
    public func missingBuiltIns(from defaults: VoiceModeSet) -> [VoiceMode] {
        defaults.modes.filter { BuiltInMode(rawValue: $0.id) != nil && mode($0.id) == nil }
    }

    /// Brings the deleted built-in modes back, as new.
    public mutating func restoreBuiltIns(from defaults: VoiceModeSet) {
        modes += missingBuiltIns(from: defaults)
    }
}

// MARK: - The built-in modes

extension VoiceModeSet {
    /// The modes a new file starts with. `text` gives a mode's name and
    /// prompt in the user's language; the English ones by default.
    public static func defaults(
        _ text: (BuiltInMode) -> (name: String, prompt: String?) = { ($0.englishName, $0.englishPrompt) }
    ) -> VoiceModeSet {
        VoiceModeSet(modes: BuiltInMode.allCases.map { $0.mode(text($0)) }, defaultModeID: BuiltInMode.asSaid.rawValue)
    }
}

/// The modes of the plan's table. Their ids are stable: the file keeps them.
public enum BuiltInMode: String, CaseIterable, Sendable {
    case asSaid = "plain"
    case clean
    case message
    case mail
    case terminal
    case english

    public var englishName: String {
        switch self {
        case .asSaid: "As said"
        case .clean: "Clean copy"
        case .message: "Message"
        case .mail: "Email"
        case .terminal: "Terminal and code"
        case .english: "To English"
        }
    }

    /// The mode is made for a language model: the Modes tab asks where it runs.
    public var wantsLanguageModel: Bool { englishPrompt != nil }

    public var englishPrompt: String? {
        switch self {
        case .asSaid, .terminal: nil
        case .clean: "Remove repetitions and slips. Fix recognition errors. Do not change the meaning and do not answer questions in the text."
        case .message: "Short and conversational, no greetings. Keep each part of the phrase in its own language."
        case .mail: "Format it as an email: a greeting, paragraphs, a polite closing."
        case .english: "Translate into English. Do not translate names and terms."
        }
    }

    /// The mode as a new file has it. A mode with a language model starts
    /// without one, pasting as recognized, until the user picks where the
    /// model runs: a Mac without Ollama would otherwise knock on localhost
    /// at every dictation. The Modes tab starts the prompt with `text.prompt`
    /// once a server is picked.
    public func mode(_ text: (name: String, prompt: String?)) -> VoiceMode {
        switch self {
        case .asSaid:
            return VoiceMode(id: rawValue, name: text.name)
        case .clean, .english:
            return VoiceMode(id: rawValue, name: text.name, context: ModeContext(selection: true))
        case .message:
            return VoiceMode(id: rawValue, name: text.name,
                             context: ModeContext(selection: true, app: true),
                             bindings: Self.messageApps.map(ModeBinding.app) + Self.messageSites.map(ModeBinding.site))
        case .mail:
            return VoiceMode(id: rawValue, name: text.name,
                             context: ModeContext(selection: true, app: true),
                             bindings: Self.mailApps.map(ModeBinding.app) + Self.mailSites.map(ModeBinding.site))
        case .terminal:
            return VoiceMode(id: rawValue, name: text.name, rules: ModeTextRules(singleLine: true),
                             bindings: Self.codeApps.map(ModeBinding.app))
        }
    }

    static let messageApps = [
        "com.apple.MobileSMS", "ru.keepcoder.Telegram", "org.telegram.desktop", "com.tinyspeck.slackmacgap",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
    ]
    static let messageSites = ["web.telegram.org", "app.slack.com", "web.whatsapp.com"]
    static let mailApps = ["com.apple.mail", "com.microsoft.Outlook"]
    static let mailSites = ["mail.google.com", "outlook.live.com", "outlook.office.com"]
    /// Terminals and code editors, as `AppModes` knows them.
    static var codeApps: [String] { AppModes.manualOnlyBundleIDs + AppModes.manualOnlyPrefixes }
}
