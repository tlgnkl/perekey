// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyVoiceCore
import SwiftUI

/// Settings → Voice → Recordings: the room they take, the folder, the term of
/// a call's audio and Time Machine. The term is only kept here: the recorder
/// removes the audio when it is due.
struct RecordingsGroup: View {
    let controller: TranscriptsController
    private let confirmsDeleteAll = State(initialValue: false)

    private var voice: VoiceSettingsStore { controller.voice }

    var body: some View {
        PKGroup(header: voiceText("Recordings")) {
            PKRow(voiceText("Recordings: \(controller.items.count)"),
                  detail: voiceText("Taking \(ModelSize.text(controller.diskUsage)) on disk")) {
                HStack(spacing: 8) {
                    Button { controller.showInFinder() } label: { voiceText("Show in Finder") }
                        .buttonStyle(.pkSecondary)
                    Button { confirmsDeleteAll.wrappedValue = true } label: { voiceText("Delete all recordings") }
                        .buttonStyle(.pkSecondary)
                        .disabled(controller.items.isEmpty)
                }
            }
            PKDivider()
            PKRow(voiceText("Record and transcribe"), detail: voiceText("The same as in the menu bar item, for when it is hidden.")) {
                VoiceEntryButtons(controller: controller)
            }
            if let entries = controller.entries {
                PKDivider()
                PKRow(voiceText("Transcripts")) {
                    Button { entries.openTranscripts() } label: { voiceText("Open Transcripts") }
                        .buttonStyle(.pkSecondary)
                }
            }
            PKDivider()
            PKRow(voiceText("Keep the audio of calls"), detail: retentionDetail) {
                Picker(selection: Binding(get: { controller.callAudioRetention },
                                          set: { controller.setCallAudioRetention($0) })) {
                    ForEach(CallAudioRetention.allCases, id: \.self) { term in
                        Text(verbatim: term.title).tag(term)
                    }
                } label: {
                    voiceText("Keep the audio of calls")
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(voice.managed.callAudioKeepDisabled)
            }
            PKDivider()
            PKRow(voiceText("Include in Time Machine"), detail: backupDetail) {
                Toggle(isOn: Binding(get: { controller.includesInBackup }, set: { controller.setIncludesInBackup($0) })) {
                    voiceText("Include in Time Machine")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
                .disabled(voice.managed.transcriptsBackupDisabled)
            }
            if let summaries = controller.summaries {
                PKDivider()
                SummaryModelPicker(modes: summaries.modes)
            }
            PKDivider()
            PKNote(voiceText("Recordings stay on this Mac. The text of a call stays when its audio is gone."))
        }
        .disabled(voice.isLocked)
        .onAppear {
            controller.reload()
        }
        .confirmationDialog(voiceText("Delete all recordings?"), isPresented: confirmsDeleteAll.projectedValue) {
            Button(role: .destructive) { controller.deleteAll() } label: { voiceText("Delete all recordings") }
        } message: {
            voiceText("The texts and the saved audio of all calls and files are deleted. Files you chose stay where they are.")
        }
    }

    private var retentionDetail: Text? {
        voice.managed.callAudioKeepDisabled ? voiceText("Set by your administrator") : nil
    }

    private var backupDetail: Text {
        voice.managed.transcriptsBackupDisabled
            ? voiceText("Set by your administrator")
            : voiceText("Off by default: calls hold other people's voices.")
    }
}

/// «Модель для конспектов»: a local model of the modes by default; a cloud
/// one only by this choice, and with the consent to send it transcripts.
private struct SummaryModelPicker: View {
    let modes: VoiceModesStore
    /// Bumped when a choice is refused, so the menu shows the kept one again.
    private let refusals = State(initialValue: 0)

    var body: some View {
        let set = modes.modes
        let options = set.summaryModelOptions
        let local = set.localLanguageModel
        PKRow(voiceText("Model for summaries"), detail: detail(local: local)) {
            Picker(selection: Binding(get: { set.summaryModel }, set: { choice in
                modes.setSummaryModel(choice)
                if modes.modes.summaryModel != choice { refusals.wrappedValue += 1 }
            })) {
                Text(verbatim: local.map { voiceString("As the modes: \(modes.title(of: $0))") }
                    ?? voiceString("As the modes: none on this Mac"))
                    .tag(SummaryModelChoice?.none)
                ForEach(options, id: \.self) { choice in
                    Text(verbatim: modes.title(of: choice)).tag(Optional(choice))
                }
            } label: {
                voiceText("Model for summaries")
            }
            .labelsHidden()
            .id(refusals.wrappedValue)
            .frame(width: 280)
            .disabled(modes.isLocked)
        }
    }

    private func detail(local: SummaryModelChoice?) -> Text {
        local == nil && modes.modes.summaryModel == nil
            ? voiceText("Set up Ollama or LM Studio in the Voice modes tab. A cloud model gets transcripts with other people’s words.")
            : voiceText("Summary and meeting minutes. A cloud model gets transcripts with other people’s words.")
    }
}

extension CallAudioRetention {
    var title: String {
        switch self {
        case .always: voiceString("Always")
        case .month: voiceString("30 days")
        case .untilTranscribed: voiceString("Delete after transcription")
        }
    }
}
#endif
