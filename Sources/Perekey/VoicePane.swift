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
    /// The text rules and the history; the Text and History groups are missing without it.
    var textController: VoiceTextController?
    /// The recordings; the Recordings group is missing without it.
    var transcripts: TranscriptsController?
    let store: SettingsStore
    let recording: ShortcutRecording

    private var microphones: [Microphone] { controller.microphones }

    private var voice: VoiceSettingsStore { controller.settings }
    private var settings: VoiceSettings { voice.settings }

    /// What the tab shows, as the Settings search needs it: a group that is not here is not found.
    static func shown(controller: VoiceModelsController, textController: VoiceTextController?,
                      transcripts: TranscriptsController?) -> Set<SettingsFlag> {
        var shown: Set<SettingsFlag> = [.voice]
        guard controller.isSupported else { return shown }
        shown.insert(.voiceSupported)
        guard !controller.settings.managed.voiceDisabled else { return shown }
        shown.insert(.voiceActive)
        if textController != nil { shown.insert(.voiceText) }
        if let transcripts {
            shown.insert(.voiceRecordings)
            if transcripts.entries != nil { shown.insert(.voiceTranscripts) }
            if transcripts.summaries != nil { shown.insert(.voiceSummaries) }
        }
        return shown
    }

    var body: some View {
        let shown = Self.shown(controller: controller, textController: textController, transcripts: transcripts)
        PKPane(title: voiceText("Voice")) {
            if !shown.contains(.voiceSupported) {
                PKGroup {
                    PKNote(voiceText("Voice input needs a Mac with Apple Silicon and macOS 15 or newer."))
                }
            } else if !shown.contains(.voiceActive) {
                dictationGroup
            } else {
                dictationGroup
                ModelsList(controller: controller) {
                    TranscriptionModelPicker(controller: controller)
                    PKDivider()
                    unloadRow
                }
                .id("models")
                captureGroup
                if shown.contains(.voiceText), let textController {
                    VoiceTextGroup(controller: textController)
                    VoiceHistoryGroup(controller: textController)
                }
                if shown.contains(.voiceRecordings), let transcripts {
                    RecordingsGroup(controller: transcripts)
                }
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

    /// The switch and the shortcut: what it takes to start talking.
    private var dictationGroup: some View {
        PKGroup {
            VoiceHero(isOn: settings.isEnabled && !voice.managed.voiceDisabled, detail: switchDetail,
                      disabled: voice.managed.voiceDisabled) { on in
                voice.update { $0.isEnabled = on }
            }
            .pkAnchor("voice.input")
            if voice.isLocked {
                PKCallout(voiceText("These voice settings were written by a newer version of Perekey. Update the app to change them."))
            }
            if !voice.managed.voiceDisabled {
                triggerRows
            }
        }
        .disabled(voice.isLocked)
    }

    /// «Диктовка»: where the sound comes from and what happens around a dictation.
    private var captureGroup: some View {
        PKGroup(header: voiceText("Dictation"), anchor: "voice.dictation") {
            microphoneRow
            // The input level meter goes here: it needs the microphone running.
            PKDivider()
            PKRow(voiceText("Switch the layout to the language of the phrase"), anchor: "voice.switch-layout") {
                flag(\.switchesLayout, label: voiceText("Switch the layout to the language of the phrase"))
            }
            PKDivider()
            PKRow(voiceText("Sounds"), anchor: "voice.sounds") { flag(\.playsSounds, label: voiceText("Sounds")) }
            PKDivider()
            autoStopRow
        }
        .disabled(!settings.isEnabled || voice.isLocked)
        .opacity(settings.isEnabled ? 1 : 0.55)
        .pkAnimation(PK.Motion.easeOut(0.32), value: settings.isEnabled)
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
        PKRow(voiceText("Shortcut"), detail: triggerDetail, anchor: "voice.shortcut") {
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
        PKRow(voiceText("Microphone"), detail: microphoneDetail, anchor: "voice.microphone") {
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
        PKRow(voiceText("Stop by itself after"), detail: voiceText("A long recording stops and is typed at this limit."),
              anchor: "voice.auto-stop") {
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
              detail: voiceText("An idle model is dropped from memory. The next dictation loads it again."),
              anchor: "voice.unload") {
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

/// «Модель для расшифровок»: files and calls. As dictation by default, on
/// this Mac; a cloud model only by this choice and with the consent to send
/// it recordings of conversations.
private struct TranscriptionModelPicker: View {
    let controller: VoiceModelsController

    var body: some View {
        let settings = controller.settings.settings
        let ready = controller.statuses.filter { $0.state == .ready && $0.entry.engine.recognizes }
        let modes = controller.modes
        let cloud = CloudSpeechModel.known.filter { model in
            modes.flatMap { store in store.modes.endpoint(model.endpoint).map(store.isUsable) } ?? false
        }
        let chosen = settings.transcriptionModel ?? ""
        PKRow(voiceText("Model for transcriptions"),
              detail: voiceText("Files and calls. A cloud model gets recordings with other people’s voices."),
              anchor: "voice.transcription-model") {
            Picker(selection: Binding(get: { chosen }, set: { id in choose(id) })) {
                Text("As dictation", tableName: "Voice").tag("")
                ForEach(ready) { Text(verbatim: ModelNames.display($0.entry)).tag($0.id) }
                ForEach(cloud, id: \.id) { Text(verbatim: "\($0.displayName) ☁").tag($0.id) }
                if !chosen.isEmpty, !ready.contains(where: { $0.id == chosen }), !cloud.contains(where: { $0.id == chosen }) {
                    Text(verbatim: ModelCatalog.entry(id: chosen).map(ModelNames.display) ?? chosen).tag(chosen)
                }
            } label: {
                voiceText("Model for transcriptions")
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    /// A cloud model needs the consent for conversations first; refused, nothing changes.
    private func choose(_ id: String) {
        if TranscriptionModel.isCloud(id), controller.modes?.askConversationConsent(model: id) != true { return }
        controller.settings.update { $0.transcriptionModel = id.isEmpty ? nil : id }
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

/// The head of the tab: a microphone tile, the title, what voice input does,
/// and its switch. On, the tile is a strip and its level bars rise one after
/// another; off, it is a plain tile with the bars down.
private struct VoiceHero: View {
    let isOn: Bool
    let detail: Text?
    let disabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VoiceTile(isOn: isOn)
            VStack(alignment: .leading, spacing: 3) {
                voiceText("Voice input")
                    .font(PK.Font.headline)
                    .foregroundStyle(Color.pkInk)
                if let detail {
                    detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(get: { isOn }, set: set)) { voiceText("Voice input") }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
                .disabled(disabled)
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
    }
}

/// 44pt tile with a microphone and four level bars.
private struct VoiceTile: View {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Heights of the bars, as a share of the tile: a word being said.
    private static let levels: [CGFloat] = [0.30, 0.62, 0.44, 0.22]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Color.pkIndigoInk : Color.pkInk2)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(Self.levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(isOn ? Color.pkIndigo : Color.pkInk3)
                        .frame(width: 2.5, height: 44 * (isOn ? level : 0.07))
                        .animation(reduceMotion ? nil : PK.Motion.settle(0.5).delay(isOn ? Double(index) * 0.06 : 0), value: isOn)
                }
            }
            .frame(height: 30)
        }
        .frame(width: 52, height: 44)
        .background {
            if isOn {
                Color.clear.glassStrip(in: shape)
            } else {
                shape.fill(Color.pkWash)
            }
        }
        .overlay { if !isOn { shape.strokeBorder(Color.pkRule, lineWidth: 0.5) } }
        .pkAnimation(PK.Motion.easeOut(0.32), value: isOn)
        .accessibilityHidden(true)
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
