// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore

/// Dictation in the app, on the voice pane's settings and model store: the
/// event tap gets the trigger, and `VoiceController` runs while dictation
/// is on. With dictation off, off by a profile, on a Mac that cannot run the
/// models, or with voice.json of a newer Perekey, nothing of it runs: no
/// microphone, no models. The network gate is the pane's
/// (`VoiceModelsController`).
@MainActor
final class VoiceSetup {
    private let input: InputController
    private let models: VoiceModelsController
    private(set) var controller: VoiceController?
    private var capture: AudioCapture?
    private var hud: VoiceHUDController?
    /// Settings → Voice, for the HUD's "Open Settings" after a model error.
    var openVoiceSettings: () -> Void = {}
    let modes: VoiceModesStore
    private lazy var runner = makeRunner()
    /// Reads the selected text for modes that send it.
    private let probe = TextProbe()
    /// Consents declined in this run: not asked again after every dictation.
    private var declined: Set<String> = []

    init(input: InputController, models: VoiceModelsController, modes: VoiceModesStore) {
        self.input = input
        self.models = models
        self.modes = modes
        models.modes = modes
        input.onVoice = { [weak self] in self?.controller?.voice($0) }
        input.onAccessLost.chain { [weak self] in self?.controller?.accessibilityLost() }
        // The dictation model, just downloaded, compiles in the background
        // in the copy dictation will use.
        models.onModelReady = { [weak self] id in
            guard let controller = self?.controller else { return }
            Task { await controller.modelDownloaded(id) }
        }
        models.settings.observe { [weak self] in self?.apply() }
    }

    private var settings: VoiceSettings { models.settings.settings }

    private var isOn: Bool { models.settings.isOn && models.isSupported && settings.activeTrigger != nil }

    private func apply() {
        // The tap's snapshot: the trigger, and the retype narrowed to the left ⌥.
        input.voiceSettings = isOn ? settings : VoiceSettings()
        guard isOn else {
            if let controller {
                self.controller = nil
                hud?.stop()
                hud = nil
                // Ends a session in progress: the microphone goes off and
                // the tap gives Esc back.
                Task { await controller.shutdown() }
            }
            return
        }
        let preferences = DictationPreferences(settings)
        if let controller {
            controller.apply(preferences)
            return
        }
        let capture = capture ?? AudioCapture()
        self.capture = capture
        let input = self.input
        let trigger = { [weak self] in self?.settings.trigger }
        controller = VoiceController(
            preferences: preferences, capture: capture, store: models.store,
            paster: TextPasterAdapter(input.textPaster), secureInput: input.dictationSecureInput,
            hooks: VoiceController.Hooks(
                sessionChanged: { input.voiceSessionChanged($0) },
                holdIsDown: { trigger()?.isHeldNow ?? false },
                holdLost: { input.voiceHoldLost() },
                pasted: { input.selectLayout(afterDictating: $0) }),
            cloudEngine: { [modes] id in Self.cloudEngine(id, modes: modes) })
        controller?.modes = runner
        if let controller {
            hud = VoiceHUDController(
                voice: controller,
                actions: VoiceHUDController.Actions(
                    openMicrophoneSettings: { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") },
                    openAccessibilitySettings: { Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") },
                    openVoiceSettings: { [weak self] in self?.openVoiceSettings() }))
        }
    }

    // MARK: Modes

    private func makeRunner() -> VoiceModeRunner {
        let input = self.input
        let modes = self.modes
        let probe = self.probe
        return VoiceModeRunner(environment: VoiceModeRunner.Environment(
            modes: { modes.modes },
            front: { input.appModes.frontmost.map { VoiceModeRunner.Front(bundleID: $0.bundleID, name: $0.name) } },
            host: {
                guard let app = input.appModes.frontmost?.bundleID, SiteObserver.browserBundleIDs.contains(app)
                else { return nil }
                return input.appModes.frontHost
            },
            selection: {
                Task {
                    await withCheckedContinuation { continuation in
                        probe.selectedText { selection in
                            if case let .text(text) = selection {
                                continuation.resume(returning: text)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                    }
                }
            },
            hasKey: { modes.hasKey($0) }, key: { modes.key($0) },
            cloudDisabled: modes.cloudDisabled,
            askConsent: { [weak self] request in
                // After the paste, on a turn of its own: the window takes the focus.
                Task { @MainActor in
                    guard let self, !self.declined.contains(request.id) else { return }
                    if !modes.ask(request) { self.declined.insert(request.id) }
                }
            }))
    }

    /// The engine of a cloud speech model: the address and the key are read
    /// for every dictation.
    private static func cloudEngine(_ id: String, modes: VoiceModesStore) -> (any SpeechEngine)? {
        guard let model = CloudSpeechModel(id: id) else { return nil }
        return CloudSTTEngine(model: model, client: OpenAICompatibleClient()) { [weak modes] in
            await MainActor.run {
                guard let modes, let endpoint = modes.modes.endpoint(model.endpoint),
                      let address = endpoint.endpointAddress
                else { return nil }
                return CloudSTTEngine.Target(address: address, key: modes.key(endpoint.id))
            }
        }
    }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

private extension Optional where Wrapped == () -> Void {
    /// Runs `next` after what is there.
    mutating func chain(_ next: @escaping () -> Void) {
        let first = self
        self = { first?(); next() }
    }
}
#endif
