// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore

/// Dictation in the app: reads voice.json, gives the event tap its trigger,
/// and runs `VoiceController` while dictation is on. With dictation off,
/// or turned off by a profile, nothing of it runs: no microphone, no
/// models, no requests.
@MainActor
final class VoiceSetup {
    private let input: InputController
    private let file = VoiceSettingsFile()
    private let managed = ManagedPreferences.read()
    private(set) var settings: VoiceSettings
    private(set) var controller: VoiceController?
    private var capture: AudioCapture?
    private var store: VoiceModelStore?
    private let secureInput = SecureInputGate()

    init(input: InputController) {
        self.input = input
        settings = file.load()
        input.onVoice = { [weak self] in self?.controller?.voice($0) }
        input.onAccessLost.chain { [weak self] in self?.controller?.accessibilityLost() }
        input.onSecureInputChanged = { [secureInput] in secureInput.changed($0) }
        apply()
    }

    /// New settings from the voice pane: saved, then applied.
    func update(_ settings: VoiceSettings) throws {
        try file.save(settings)
        self.settings = settings
        apply()
    }

    private var isOn: Bool { settings.activeTrigger != nil && !managed.voiceDisabled }

    private func apply() {
        input.voiceSettings = isOn ? settings : VoiceSettings()
        guard isOn else {
            if let controller {
                self.controller = nil
                Task { await controller.unloadModels() }
            }
            return
        }
        if let controller {
            controller.apply(settings)
            return
        }
        let capture = capture ?? AudioCapture()
        let store = store ?? VoiceModelStore(managed: managed)
        self.capture = capture
        self.store = store
        let input = self.input
        let trigger = { [weak self] in self?.settings.trigger }
        controller = VoiceController(
            settings: settings, capture: capture, store: store, paster: PendingPaster(), secureInput: secureInput,
            hooks: VoiceController.Hooks(
                sessionChanged: { input.voiceSessionChanged($0) },
                holdIsDown: { trigger()?.isHeldNow ?? false },
                holdLost: { input.voiceHoldLost() },
                pasted: { input.selectLayout(afterDictating: $0) }))
    }
}

/// Until `TextPaster` (the paste lane) is in: nothing is pasted, the text
/// stays in `VoiceController.lastText` and the HUD offers to copy it.
@MainActor
private final class PendingPaster: DictationPaster {
    func captureTarget() async -> (any Sendable)? { nil }

    func paste(_: String, into _: (any Sendable)?) async -> DictationPasteResult {
        .failed("no paster yet")
    }
}

/// Until `DictationSecureInput` (the paste lane) is in: no start under
/// Secure Input, a stop when it comes on during a session. No Esc hot key.
@MainActor
private final class SecureInputGate: DictationSecureInputRules {
    var onStop: (@MainActor () -> Void)?
    var onEscape: (@MainActor () -> Void)?
    private var inSession = false

    var allowsStart: Bool { !SecureInput.isEnabled }
    func sessionBegan() { inSession = true }
    func sessionEnded() { inSession = false }

    func changed(_ on: Bool) {
        if on, inSession { onStop?() }
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
