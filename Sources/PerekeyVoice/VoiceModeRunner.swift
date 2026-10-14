// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore

/// A request for consent: the window names the host and what would go there.
public struct ConsentRequest: Hashable, Sendable, Identifiable {
    public var endpointID: String
    public var endpointName: String
    public var host: String
    /// What the mode sends there, all of it: the window lists it whole.
    public var data: ModeData
    public var modeName: String

    public var id: String { "\(endpointID)|\(data.rawValue)" }

    public init(endpointID: String, endpointName: String, host: String, data: ModeData, modeName: String) {
        self.endpointID = endpointID
        self.endpointName = endpointName
        self.host = host
        self.data = data
        self.modeName = modeName
    }
}

/// The modes for dictation: resolves the mode of a session from the app and
/// the site in front, decides which of its cloud steps may run, and runs its
/// language model through `OpenAICompatibleClient`.
///
/// A step runs only with everything it needs: a usable address, the key if
/// the endpoint needs one, consent for all the mode sends there, and no
/// `VoiceCloudDisabled` for a server off this Mac. Otherwise the session
/// skips it (`ModeFallback`): the local model hears the dictation, or it goes
/// in as recognized. A missing consent is asked once the session is over,
/// never in the middle of it, so the window does not take the paste's focus.
@MainActor
public final class VoiceModeRunner: DictationModeSource {
    /// The app in front.
    public struct Front: Hashable, Sendable {
        public var bundleID: String
        public var name: String

        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// What the runner reads of the app.
    public struct Environment {
        public var modes: @MainActor () -> VoiceModeSet
        public var front: @MainActor () -> Front?
        /// The normalized host of the page in front, in a browser; nil elsewhere.
        public var host: @MainActor () -> String?
        /// Starts reading the selected text of the focused field.
        public var selection: @MainActor () -> Task<String?, Never>
        public var hasKey: @MainActor (String) -> Bool
        public var key: @MainActor (String) -> String?
        /// `VoiceCloudDisabled`.
        public var cloudDisabled: @MainActor () -> Bool
        /// Whether a speech model of this Mac is downloaded and checked.
        public var isModelReady: @MainActor (String) -> Bool
        /// Shows the consent window.
        public var askConsent: @MainActor (ConsentRequest) -> Void

        public init(modes: @escaping @MainActor () -> VoiceModeSet, front: @escaping @MainActor () -> Front?,
                    host: @escaping @MainActor () -> String?,
                    selection: @escaping @MainActor () -> Task<String?, Never> = { Task { nil } },
                    hasKey: @escaping @MainActor (String) -> Bool, key: @escaping @MainActor (String) -> String?,
                    cloudDisabled: @escaping @MainActor () -> Bool,
                    isModelReady: @escaping @MainActor (String) -> Bool = { _ in true },
                    askConsent: @escaping @MainActor (ConsentRequest) -> Void)
        {
            self.isModelReady = isModelReady
            self.modes = modes
            self.front = front
            self.host = host
            self.selection = selection
            self.hasKey = hasKey
            self.key = key
            self.cloudDisabled = cloudDisabled
            self.askConsent = askConsent
        }
    }

    /// The most selected text the language model sees.
    public static let selectionLimit = 4_000
    /// The wait for a language model on this Mac: a cold one loads first.
    public static let localTimeout: Duration = .seconds(30)
    public static let cloudTimeout: Duration = .seconds(20)

    private let environment: Environment
    private let client: OpenAICompatibleClient

    public init(environment: Environment, client: OpenAICompatibleClient = OpenAICompatibleClient()) {
        self.environment = environment
        self.client = client
    }

    // MARK: DictationModeSource

    public func plan() -> DictationPlan {
        let set = environment.modes()
        let front = environment.front()
        let host = environment.host()
        guard let mode = ModeResolver.resolve(bundleID: front?.bundleID, host: host, in: set)?.mode else {
            return DictationPlan(modeID: "", modeName: "")
        }
        let singleLine = mode.rules.singleLine || Terminals.contains(front?.bundleID)
        var plan = DictationPlan(
            modeID: mode.id, modeName: mode.name,
            output: singleLine && mode.output == .pasteAndEnter ? .paste : mode.output,
            singleLine: singleLine, removesFillers: mode.rules.removesFillers, appName: front?.name, host: host)
        guard set.newerSchemaVersion == nil else {
            if !mode.endpoints.isEmpty { plan.fallback = .modesLocked }
            return plan
        }
        if let model = mode.model {
            if let cloud = CloudSpeechModel(id: model) {
                switch check(cloud.endpoint, for: mode, in: set) {
                case let .ready(address, _):
                    plan.speechModel = model
                    plan.speechHost = address.displayHost
                case let .skip(fallback):
                    plan.fallback = fallback
                }
            } else if environment.isModelReady(model) {
                plan.speechModel = model
            }
            // A model of this Mac that is not downloaded: the voice settings' one hears it.
        }
        if let refine = mode.refine {
            switch check(refine.endpoint, for: mode, in: set) {
            case let .ready(address, name):
                plan.refine = DictationPlan.Refine(
                    endpointName: name, isCloud: !address.isOnThisMac,
                    timeout: address.isOnThisMac ? Self.localTimeout : Self.cloudTimeout)
                if mode.context.selection { plan.selection = environment.selection() }
            case let .skip(fallback):
                plan.fallback = plan.fallback ?? fallback
            }
        }
        return plan
    }

    public func refine(_ text: String, plan: DictationPlan) async throws -> String {
        let set = environment.modes()
        guard let mode = set.mode(plan.modeID), let config = mode.refine,
              case let .ready(address, _) = check(config.endpoint, for: mode, in: set)
        else { throw OpenAICompatibleClient.Failure.blocked }
        var selection: String?
        if mode.context.selection, let selected = await plan.selection?.value,
           selected.contains(where: { !$0.isWhitespace })
        {
            selection = String(selected.prefix(Self.selectionLimit))
        }
        let prompt = RefinePrompt(instruction: config.prompt, dictation: text, selection: selection,
                                  app: mode.context.app ? plan.appName : nil,
                                  site: mode.context.site ? plan.host : nil)
        return try await client.complete(prompt.messages, model: config.model, address: address,
                                         key: environment.key(config.endpoint))
    }

    public func sessionEnded(_ plan: DictationPlan) {
        guard case .needsConsent = plan.fallback, let request = consentRequest(for: plan.modeID) else { return }
        environment.askConsent(request)
    }

    // MARK: Checks

    enum Check {
        case ready(EndpointAddress, name: String)
        case skip(ModeFallback)
    }

    /// Whether `mode` may send to `endpoint` now.
    func check(_ endpoint: String, for mode: VoiceMode, in set: VoiceModeSet) -> Check {
        guard let found = set.endpoint(endpoint), let address = found.endpointAddress else { return .skip(.failed) }
        if !address.isOnThisMac {
            if environment.cloudDisabled() { return .skip(.cloudOff) }
            if found.needsKey, !environment.hasKey(endpoint) { return .skip(.needsKey(endpoint: found.name)) }
            if !set.missingConsent(mode, endpoint: endpoint).isEmpty {
                return .skip(.needsConsent(host: address.displayHost))
            }
        }
        return .ready(address, name: found.name)
    }

    /// The first endpoint of the mode that waits for consent, with all the
    /// mode sends there.
    public func consentRequest(for modeID: String) -> ConsentRequest? {
        let set = environment.modes()
        guard let mode = set.mode(modeID), !environment.cloudDisabled() else { return nil }
        for id in mode.endpoints {
            guard let endpoint = set.endpoint(id), let address = endpoint.endpointAddress,
                  !set.missingConsent(mode, endpoint: id).isEmpty,
                  !endpoint.needsKey || environment.hasKey(id)
            else { continue }
            return ConsentRequest(endpointID: id, endpointName: endpoint.name, host: address.displayHost,
                                  data: mode.data(for: id), modeName: mode.name)
        }
        return nil
    }
}
