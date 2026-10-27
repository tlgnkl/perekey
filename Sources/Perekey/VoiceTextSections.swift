// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyInput
import PerekeyVoiceCore
import SwiftUI

/// Settings → Voice → Text: the replacement dictionary and the filler words.
struct VoiceTextGroup: View {
    let controller: VoiceTextController
    private let from = State(initialValue: "")
    private let to = State(initialValue: "")

    private var store: VoiceTextStore { controller.text }
    private var settings: VoiceTextSettings { store.settings }
    private var canAdd: Bool {
        !from.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
            && !to.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        PKGroup(header: voiceText("Text"), anchor: "voice.text") {
            PKRow(voiceText("Remove filler words"),
                  detail: voiceText("Drops “um”, “uh”, “э-э”. “Ну” and “как бы”: only between commas."),
                  anchor: "voice.fillers") {
                Toggle(isOn: Binding(get: { settings.removesFillers },
                                     set: { on in store.update { $0.removesFillers = on } })) {
                    voiceText("Remove filler words")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
            }
            PKDivider()
            PKNote(voiceText("Replacements. When Perekey hears the left side, it types the right side. Case does not matter; only whole words match."))
            HStack(spacing: 8) {
                TextField("", text: from.projectedValue, prompt: voiceText("You say"))
                    .labelsHidden()
                    .pkField()
                    .onSubmit(add)
                Image(systemName: "arrow.right").foregroundStyle(Color.pkInk3).accessibilityHidden(true)
                TextField("", text: to.projectedValue, prompt: voiceText("Perekey types"))
                    .labelsHidden()
                    .pkField()
                    .onSubmit(add)
                Button(action: add) { voiceText("Add") }
                    .buttonStyle(.pkPrimary)
                    .disabled(!canAdd)
            }
            .padding(PK.Space.md)
            if settings.dictionary.isEmpty {
                PKDivider()
                PKNote(voiceText("No replacements yet."))
            }
            ForEach(settings.dictionary) { entry in
                PKDivider()
                PKRow(Text(verbatim: entry.from + "  →  " + entry.to)) {
                    Button { store.removeEntry(entry) } label: { voiceText("Remove") }
                        .buttonStyle(.pkLink)
                }
            }
        }
        .disabled(store.isLocked)
    }

    private func add() {
        guard store.setEntry(from: from.wrappedValue, to: to.wrappedValue) else { return }
        from.wrappedValue = ""
        to.wrappedValue = ""
    }
}

/// Settings → Voice → History: the term, the audio, the folder and the eraser.
struct VoiceHistoryGroup: View {
    let controller: VoiceTextController
    private let confirmsClear = State(initialValue: false)

    private var store: VoiceTextStore { controller.text }
    private var settings: VoiceTextSettings { store.settings }

    var body: some View {
        PKGroup(header: voiceText("History"), anchor: "voice.history") {
            PKRow(voiceText("Keep dictations for"), detail: retentionDetail, anchor: "voice.history-retention") {
                Picker(selection: Binding(get: { store.effectiveRetention },
                                          set: { value in store.update { $0.retention = value } })) {
                    ForEach(store.availableRetentions, id: \.self) { term in
                        Text(verbatim: term.title).tag(term)
                    }
                } label: {
                    voiceText("Keep dictations for")
                }
                .labelsHidden()
                .frame(width: 140)
            }
            PKDivider()
            PKRow(voiceText("Keep the audio of dictations"),
                  detail: voiceText("Saved as .aac files for the same time. Off by default; turning it off deletes the files."),
                  anchor: "voice.history-audio") {
                Toggle(isOn: Binding(get: { settings.keepsAudio },
                                     set: { on in store.update { $0.keepsAudio = on } })) {
                    voiceText("Keep the audio of dictations")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
                .disabled(store.effectiveRetention == .off)
            }
            PKDivider()
            PKNote(voiceText("The history stays on this Mac and out of Time Machine. Password fields and excluded apps never reach it."))
            PKDivider()
            PKRow(voiceText("\(controller.history.entries.count) dictations")) {
                HStack(spacing: 8) {
                    Button { NSWorkspace.shared.open(controller.history.folderURL) } label: { voiceText("Show in Finder") }
                        .buttonStyle(.pkSecondary)
                    Button { confirmsClear.wrappedValue = true } label: { voiceText("Clear history") }
                        .buttonStyle(.pkSecondary)
                        .disabled(controller.history.entries.isEmpty)
                }
            }
        }
        .disabled(store.isLocked)
        .confirmationDialog(voiceText("Clear the history?"), isPresented: confirmsClear.projectedValue) {
            Button(role: .destructive) { controller.history.clear() } label: { voiceText("Clear history") }
        } message: {
            voiceText("The texts and saved audio of all dictations are deleted.")
        }
    }

    private var retentionDetail: Text? {
        guard let days = store.managed.voiceHistoryMaxDays else { return nil }
        return days == 0
            ? voiceText("Your administrator turned the history off.")
            : voiceText("Your administrator limits it to \(days) days.")
    }
}

extension HistoryRetention {
    var title: String {
        switch self {
        case .off: voiceString("Don't keep")
        case .day: voiceString("1 day")
        case .week: voiceString("1 week")
        case .month: voiceString("1 month")
        }
    }
}
#endif
