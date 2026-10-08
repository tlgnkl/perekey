// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import SwiftUI

/// Settings → Words: the words Perekey never corrects. "My words" are typed in
/// by the user; "Learned" ones come from undone corrections.
struct WordsPane: View {
    let store: SettingsStore
    /// Says whether a word is among the 1000 most frequent. The classifier model will provide it.
    var isFrequent: (String) -> Bool = { _ in false }

    private let draft: State<String>

    init(store: SettingsStore, isFrequent: @escaping (String) -> Bool = { _ in false }, initialDraft: String = "") {
        self.store = store
        self.isFrequent = isFrequent
        draft = State(initialValue: initialDraft)
    }

    private var words: WordExceptions { store.settings.words }
    private var validation: WordExceptions.Validation { words.validate(draft.wrappedValue, isFrequent: isFrequent) }

    var body: some View {
        Form {
            Section {
                Text("Perekey never corrects these words, in any layout.")
                    .foregroundStyle(.secondary)
            }
            mineSection
            learnedSection
        }
        .formStyle(.grouped)
    }

    private var mineSection: some View {
        Section {
            HStack {
                TextField("Word", text: draft.projectedValue, prompt: Text("Add a word"))
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(![.ok, .frequent].contains(validation))
            }
            if let message = message {
                Label(message.text, systemImage: message.symbol)
                    .foregroundStyle(message.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .font(.callout)
            }
            if words.mine.isEmpty {
                Text("No words yet.").foregroundStyle(.secondary)
            }
            ForEach(words.mine, id: \.self) { word in
                LabeledContent {
                    Button("Remove") { store.update { $0.words.remove(word) } }
                        .buttonStyle(.borderless)
                } label: {
                    Text(word)
                }
            }
        } header: {
            Text("My words") + Text(count(words.mine.count)).foregroundStyle(.tertiary)
        }
    }

    private var learnedSection: some View {
        Section {
            Toggle("Learn from undone corrections", isOn: learnBinding)
            if words.learned.isEmpty {
                Text("Words you undo after a correction appear here.").foregroundStyle(.secondary)
            }
            ForEach(words.learned, id: \.word) { item in
                LabeledContent {
                    HStack(spacing: 12) {
                        Text(Date(timeIntervalSince1970: item.learnedAt).formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                        Button("Forget") { store.update { $0.words.forget(item.word) } }
                            .buttonStyle(.borderless)
                    }
                } label: {
                    Text(item.word)
                }
            }
            if !words.learned.isEmpty {
                Button("Forget all") { store.update { $0.words.forgetAllLearned() } }
            }
        } header: {
            Text("Learned") + Text(count(words.learned.count)).foregroundStyle(.tertiary)
        }
    }

    private func count(_ number: Int) -> String { number == 0 ? "" : "  \(number)" }

    private var learnBinding: Binding<Bool> {
        Binding(
            get: { store.settings.words.learnFromUndos },
            set: { value in store.update { $0.words.learnFromUndos = value } }
        )
    }

    private func add() {
        guard [.ok, .frequent].contains(validation) else { return }
        let word = draft.wrappedValue
        store.update { $0.words.add(word) }
        draft.wrappedValue = ""
    }

    private var message: (text: LocalizedStringKey, symbol: String, warning: Bool)? {
        switch validation {
        case .ok, .empty: nil
        case .invalid: ("Use one word: letters, apostrophe and hyphen.", "xmark.circle", false)
        case .duplicate: ("This word is already on a list.", "info.circle", false)
        case .frequent: ("This word will stop being corrected everywhere.", "exclamationmark.triangle.fill", true)
        }
    }
}
