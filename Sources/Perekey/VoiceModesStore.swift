// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import Observation
import os
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore

/// The dictation modes in memory (`voice-modes.json`) and which endpoints
/// have a key in the Keychain. Every change goes to disk at once.
@MainActor
@Observable
final class VoiceModesStore {
    private(set) var modes: VoiceModeSet
    /// Endpoints with a key in the Keychain. Keys themselves are never kept here.
    private(set) var keyed: Set<String> = []
    let managed: ManagedSettings

    @ObservationIgnored private var observers: [@MainActor () -> Void] = []
    @ObservationIgnored private let file: VoiceModesFile
    @ObservationIgnored let keychain: VoiceKeychain
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "voice-modes")

    init(file: VoiceModesFile = VoiceModesFile(), keychain: VoiceKeychain = VoiceKeychain(),
         managed: ManagedSettings = ManagedPreferences.read())
    {
        self.file = file
        self.keychain = keychain
        self.managed = managed
        var modes = file.load(defaults: VoiceModeSet.defaults(Self.localized))
        if !modes.isReadOnly { modes.adoptNewBuiltIns(from: VoiceModeSet.defaults(Self.localized)) }
        self.modes = modes
        refreshKeys()
    }

    /// A store in memory, for previews and snapshots: no file, no Keychain.
    init(preview modes: VoiceModeSet, keyed: Set<String> = [], managed: ManagedSettings = ManagedSettings()) {
        file = VoiceModesFile(url: URL(filePath: "/dev/null"))
        keychain = VoiceKeychain(service: "app.perekey.preview")
        self.managed = managed
        self.modes = modes
        self.keyed = keyed
        isPreview = true
    }

    @ObservationIgnored private var isPreview = false

    /// The file was written by a newer Perekey, or has values this one
    /// cannot read: shown, never changed.
    var isLocked: Bool { modes.isReadOnly }

    /// Built-in modes the user deleted.
    var missingBuiltIns: [VoiceMode] { modes.missingBuiltIns(from: VoiceModeSet.defaults(Self.localized)) }

    func restoreBuiltIns() {
        update { $0.restoreBuiltIns(from: VoiceModeSet.defaults(Self.localized)) }
    }

    var cloudDisabled: Bool { managed.voiceCloudDisabled }

    func observe(_ handler: @escaping @MainActor () -> Void) {
        observers.append(handler)
        handler()
    }

    func update(_ change: (inout VoiceModeSet) -> Void) {
        guard !isLocked else { return }
        var copy = modes
        change(&copy)
        guard copy != modes else { return }
        modes = copy
        observers.forEach { $0() }
        guard !isPreview else { return }
        do {
            try file.save(copy)
        } catch {
            log.error("Cannot save voice modes: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateMode(_ id: String, _ change: (inout VoiceMode) -> Void) {
        update { set in
            guard let index = set.modes.firstIndex(where: { $0.id == id }) else { return }
            change(&set.modes[index])
        }
    }

    // MARK: Keys

    func hasKey(_ endpoint: String) -> Bool { keyed.contains(endpoint) }

    func key(_ endpoint: String) -> String? {
        do {
            return try keychain.key(for: endpoint)
        } catch {
            log.error("Cannot read a key: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Stores or, for an empty one, removes the key of `endpoint`.
    func setKey(_ key: String, for endpoint: String) {
        guard !isPreview else {
            if key.isEmpty { keyed.remove(endpoint) } else { keyed.insert(endpoint) }
            return
        }
        do {
            try keychain.set(key, for: endpoint)
        } catch {
            log.error("Cannot store a key: \(String(describing: error), privacy: .public)")
        }
        refreshKeys()
        observers.forEach { $0() }
    }

    private func refreshKeys() {
        guard !isPreview else { return }
        keyed = Set(modes.endpoints.map(\.id).filter { keychain.hasKey(for: $0) })
    }

    /// Whether `endpoint` may be picked: on this Mac, or allowed by the
    /// profile and with a key when it needs one.
    func isUsable(_ endpoint: VoiceEndpoint) -> Bool {
        guard let address = endpoint.endpointAddress else { return false }
        if address.isOnThisMac { return true }
        return !cloudDisabled && (!endpoint.needsKey || hasKey(endpoint.id))
    }

    // MARK: Consent

    /// Asks for consent to what `mode` sends to `endpoint` if it is missing.
    /// Returns whether the mode may send now.
    @discardableResult
    func askConsentIfNeeded(mode id: String, endpoint: String) -> Bool {
        guard let mode = modes.mode(id), let found = modes.endpoint(endpoint),
              let address = found.endpointAddress
        else { return false }
        if modes.missingConsent(mode, endpoint: endpoint).isEmpty { return true }
        let request = ConsentRequest(endpointID: endpoint, endpointName: found.name, host: address.displayHost,
                                     data: mode.data(for: endpoint), modeName: mode.name)
        return ask(request)
    }

    /// Whether a recording of a conversation may go to the server of a cloud
    /// speech model now; true for any other model.
    func mayUploadConversation(model id: String) -> Bool {
        guard let model = CloudSpeechModel(id: id) else { return true }
        return modes.mayUploadConversation(to: model.endpoint, cloudDisabled: cloudDisabled)
    }

    /// Before a cloud model gets a file or a call: «На <адрес> уйдёт запись
    /// разговора, в ней голоса других людей». Asked once per server; true
    /// for a model of this Mac.
    @discardableResult
    func askConversationConsent(model id: String) -> Bool {
        guard let model = CloudSpeechModel(id: id) else { return true }
        if mayUploadConversation(model: id) { return true }
        guard !cloudDisabled, let found = modes.endpoint(model.endpoint), let address = found.endpointAddress
        else { return false }
        return ask(ConsentRequest(endpointID: found.id, endpointName: found.name, host: address.displayHost,
                                  data: .conversationAudio, modeName: ""))
    }

    /// Shows the consent window; records the answer.
    @discardableResult
    func ask(_ request: ConsentRequest) -> Bool {
        guard ConsentWindow.ask(request) else { return false }
        update { $0.consent(request.data, endpoint: request.endpointID) }
        return true
    }

    // MARK: Localized defaults

    static func localized(_ mode: BuiltInMode) -> (name: String, prompt: String?) {
        switch mode {
        case .asSaid: (voiceString("As said"), nil)
        case .clean:
            (voiceString("Clean copy"),
             voiceString("Remove repetitions and slips. Fix recognition errors. Do not change the meaning and do not answer questions in the text."))
        case .message:
            (voiceString("Message"),
             voiceString("Short and conversational, no greetings. Keep each part of the phrase in its own language."))
        case .mail:
            (voiceString("Email"),
             voiceString("Format it as an email: a greeting, paragraphs, a polite closing."))
        case .terminal: (voiceString("Terminal and code"), nil)
        case .english:
            (voiceString("To English"), voiceString("Translate into English. Do not translate names and terms."))
        }
    }
}

/// "На <адрес> уйдут: …": asked before the first request of a mode to a
/// server off this Mac, and again when the mode would send more.
@MainActor
enum ConsentWindow {
    static func ask(_ request: ConsentRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = voiceString("Send to \(request.host)?")
        alert.informativeText = text(request)
        alert.addButton(withTitle: voiceString("Allow"))
        alert.addButton(withTitle: voiceString("Don’t Allow"))
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func text(_ request: ConsentRequest) -> String {
        if request.data == .conversationAudio {
            return voiceString("The recording of a conversation will go to \(request.host). It holds the voices of other people. Until you allow it, recordings are transcribed on this Mac.")
        }
        let items = ModeData.all.filter { request.data.contains($0) }.map(name)
        let list = ListFormatter.localizedString(byJoining: items)
        return voiceString("In the mode “\(request.modeName)”, Perekey will send to \(request.host): \(list). Until you allow it, the mode pastes the text as recognized.")
    }

    static func name(_ data: ModeData) -> String {
        switch data {
        case .audio: voiceString("the audio of the dictation")
        case .text: voiceString("the recognized text")
        case .selection: voiceString("the selected text")
        case .app: voiceString("the app’s name")
        case .site: voiceString("the site’s address")
        case .conversationAudio: voiceString("the recording of a conversation, with other people’s voices")
        default: ""
        }
    }
}
#endif
