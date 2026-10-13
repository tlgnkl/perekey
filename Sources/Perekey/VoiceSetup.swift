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

    init(input: InputController, models: VoiceModelsController) {
        self.input = input
        self.models = models
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
                pasted: { input.selectLayout(afterDictating: $0) }))
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
