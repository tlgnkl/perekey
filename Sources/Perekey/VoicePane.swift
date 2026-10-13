// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// Strings of the Voice tab live in their own table (`Voice.strings`).
func voiceText(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "Voice") }
func voiceString(_ key: String.LocalizationValue) -> String { String(localized: key, table: "Voice") }

/// Settings → Voice: the switch, the trigger, the microphone, the model and
/// the list of models.
struct VoicePane: View {
    let controller: VoiceModelsController
    let store: SettingsStore
    let recording: ShortcutRecording

    private var microphones: [Microphone] { controller.microphones }

    private var voice: VoiceSettingsStore { controller.settings }
    private var settings: VoiceSettings { voice.settings }

    var body: some View {
        PKPane(title: voiceText("Voice")) {
            if !controller.isSupported {
                PKGroup {
                    PKNote(voiceText("Voice input needs a Mac with Apple Silicon and macOS 15 or newer."))
                }
            } else if voice.managed.voiceDisabled {
                dictationGroup
            } else {
                dictationGroup
                ModelsList(controller: controller)
            }
        }
        .onAppear {
            controller.refreshMicrophones()
            controller.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshMicrophones()
        }
    }

    // MARK: Dictation

    private var dictationGroup: some View {
        PKGroup {
            PKRow(voiceText("Voice input"), detail: switchDetail) {
                Toggle(isOn: Binding(get: { settings.isEnabled && !voice.managed.voiceDisabled },
                                     set: { on in voice.update { $0.isEnabled = on } })) {
                    voiceText("Voice input")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
                .disabled(voice.managed.voiceDisabled)
            }
            if voice.isLocked {
                PKCallout(voiceText("These voice settings were written by a newer version of Perekey. Update the app to change them."))
            }
            if !voice.managed.voiceDisabled {
                triggerRows
                Group {
                    PKDivider()
                    microphoneRow
                    // The input level meter goes here: it needs the microphone running.
                    PKDivider()
                    VoiceModelPicker(controller: controller)
                    PKDivider()
                    PKRow(voiceText("Switch the layout to the language of the phrase")) {
                        flag(\.switchesLayout, label: voiceText("Switch the layout to the language of the phrase"))
                    }
                    PKDivider()
                    PKRow(voiceText("Sounds")) { flag(\.playsSounds, label: voiceText("Sounds")) }
                    PKDivider()
                    autoStopRow
                    PKDivider()
                    unloadRow
                }
                .disabled(!settings.isEnabled)
                .opacity(settings.isEnabled ? 1 : 0.55)
            }
        }
        .disabled(voice.isLocked)
    }

    private var switchDetail: Text? {
        if voice.managed.voiceDisabled { return voiceText("Disabled by your administrator") }
        return voiceText("Speak, and Perekey types what you said where the cursor is.")
    }

    private func flag(_ key: WritableKeyPath<VoiceSettings, Bool>, label: Text) -> some View {
        Toggle(isOn: Binding(get: { settings[keyPath: key] }, set: { on in voice.update { $0[keyPath: key] = on } })) {
            label
        }
        .labelsHidden()
        .toggleStyle(.pkSwitch)
    }

    // MARK: Trigger

    @ViewBuilder private var triggerRows: some View {
        PKDivider()
        PKRow(voiceText("Shortcut"), detail: triggerDetail) {
            HStack(spacing: 8) {
                if settings.trigger != .default {
                    Button { voice.update { $0.trigger = .default } } label: {
                        voiceText("Right ⌥")
                    }
                    .buttonStyle(.pkLink)
                    .help(voiceText("Back to a tap of the right Option key"))
                }
                VoiceTriggerButton(trigger: settings.trigger, recording: recording) { trigger in
                    voice.update { $0.trigger = trigger }
                }
            }
        }
        if settings.isEnabled {
            ForEach(conflicts, id: \.self) { conflict in
                PKCallout(Text(verbatim: TriggerText.warning(for: conflict)))
            }
            if retypeMoves {
                PKNote(voiceText("Retype is now the left ⌥. The right ⌥ is for voice. Pick another key here to keep ⌥ as it was."))
            }
        }
    }

    private var triggerDetail: Text {
        switch settings.trigger {
        case .tap: voiceText("Tap to start, tap again to stop. Or record a key with modifiers to hold while you speak.")
        case .hold: voiceText("Hold while you speak, let go to type. Or record modifiers alone to tap.")
        }
    }

    private var conflicts: [ShortcutConflict] {
        ShortcutConflicts.check(voice: settings.trigger, among: store.settings.hotkeys, system: controller.systemShortcuts)
    }

    /// The right ⌥ is voice, so the retype on ⌥ takes the left one only.
    private var retypeMoves: Bool {
        settings.trigger.narrowing(store.settings.hotkeys) != store.settings.hotkeys
    }

    // MARK: Microphone, model, limits

    private var microphoneRow: some View {
        PKRow(voiceText("Microphone"), detail: microphoneDetail) {
            Picker(selection: Binding(get: { settings.microphoneUID ?? "" },
                                      set: { uid in
                                          let name = microphones.first { $0.uid == uid }?.name
                                          voice.update { $0.microphoneUID = uid.isEmpty ? nil : uid; $0.microphoneName = name }
                                      })) {
                voiceText("System").tag("")
                ForEach(microphones, id: \.uid) { Text(verbatim: $0.name).tag($0.uid) }
                if let missing = missingMicrophone {
                    Divider()
                    Text(verbatim: voiceString("Unavailable: \(settings.microphoneName ?? missing)")).tag(missing)
                }
            } label: {
                voiceText("Microphone")
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    /// The saved device is not plugged in.
    private var missingMicrophone: String? {
        guard let uid = settings.microphoneUID, !microphones.contains(where: { $0.uid == uid }) else { return nil }
        return uid
    }

    private var microphoneDetail: Text? {
        missingMicrophone == nil ? nil : voiceText("This microphone is not connected. Perekey uses the system one meanwhile.")
    }

    private var autoStopRow: some View {
        PKRow(voiceText("Stop by itself after"), detail: voiceText("A long recording stops and is typed at this limit.")) {
            Picker(selection: Binding(get: { settings.autoStop }, set: { value in voice.update { $0.autoStop = value } })) {
                ForEach(VoiceAutoStop.allCases, id: \.self) { value in
                    Text(verbatim: value.title).tag(value)
                }
            } label: {
                voiceText("Stop by itself after")
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private var unloadRow: some View {
        PKRow(voiceText("Unload the model after"),
              detail: voiceText("An idle model is dropped from memory. The next dictation loads it again.")) {
            Picker(selection: Binding(get: { settings.unload }, set: { value in voice.update { $0.unload = value } })) {
                ForEach(VoiceUnload.allCases, id: \.self) { value in
                    Text(verbatim: value.title).tag(value)
                }
            } label: {
                voiceText("Unload the model after")
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }
}

/// The model choice on its own, so that a progress tick of a download redraws
/// this row and not the whole tab.
private struct VoiceModelPicker: View {
    let controller: VoiceModelsController

    var body: some View {
        let settings = controller.settings.settings
        let ready = controller.statuses.filter { $0.state == .ready && $0.entry.engine.recognizes }
        PKRow(voiceText("Model"), detail: ready.isEmpty ? voiceText("Download a model below first.") : nil) {
            Picker(selection: Binding(get: { settings.model },
                                      set: { id in controller.settings.update { $0.model = id } })) {
                ForEach(ready) { Text(verbatim: ModelNames.display($0.entry)).tag($0.id) }
                if !ready.contains(where: { $0.id == settings.model }) {
                    Text(verbatim: ModelCatalog.entry(id: settings.model).map {
                        voiceString("\(ModelNames.display($0)) (not downloaded)")
                    } ?? settings.model).tag(settings.model)
                }
            } label: {
                voiceText("Model")
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }
}

extension VoiceAutoStop {
    var title: String {
        switch self {
        case .off: voiceString("Don't stop")
        case .seconds15: voiceString("15 s")
        case .seconds30: voiceString("30 s")
        case .seconds60: voiceString("60 s")
        }
    }
}

extension VoiceUnload {
    var title: String {
        switch self {
        case .minutes10: voiceString("10 min")
        case .minutes60: voiceString("60 min")
        case .never: voiceString("Don't unload")
        }
    }
}

/// The trigger as keycaps on a recorder plate; a click records another.
struct VoiceTriggerButton: View {
    let trigger: VoiceTrigger
    let recording: ShortcutRecording
    let onRecorded: (VoiceTrigger) -> Void

    var body: some View {
        let isRecording = recording.isRecordingVoice
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording.toggleVoice(onRecorded: onRecorded) } label: {
                Group {
                    if isRecording {
                        voiceText("Press a shortcut…").font(PK.Font.caption).foregroundStyle(Color.pkIndigoInk)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(TriggerText.keycaps(of: trigger.shortcut).enumerated()), id: \.offset) { _, cap in
                                PKKeycap(text: cap)
                            }
                            if case .tap = trigger {
                                voiceText("tap").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: 96, minHeight: 28)
                .background(RecorderPlate(recording: isRecording))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pkAnimation(PK.Motion.easeOut(0.2), value: isRecording)
            .accessibilityLabel(voiceText("Voice shortcut"))
            .accessibilityValue(Text(verbatim: TriggerText.keycaps(of: trigger.shortcut).joined(separator: " ")))
            if isRecording, let hint = recording.hint {
                Text(hint).font(PK.Font.caption).foregroundStyle(Color.pkWarn)
            }
        }
    }
}
#endif
