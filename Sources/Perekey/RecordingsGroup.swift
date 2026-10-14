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
