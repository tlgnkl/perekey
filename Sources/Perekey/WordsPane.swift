// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import SwiftUI

/// Settings → Words: the user's word rules. "Don't touch: mine" are typed in
/// by the user, "Don't touch: learned" come from undone corrections, and
/// "Always fix" switch at the word end whatever the score.
struct WordsPane: View {
    let store: SettingsStore
    /// The installed layouts: a word conflicts with a list in any of its readings.
    var layouts: [LayoutMap] = []
    /// Says whether a word is among the 1000 most frequent. The classifier model will provide it.
    var isFrequent: (String) -> Bool = { _ in false }

    private let draft: State<String>
    private let alwaysDraft: State<String>
    private let found = State(initialValue: FoundTracker())

    init(store: SettingsStore, layouts: [LayoutMap] = [], isFrequent: @escaping (String) -> Bool = { _ in false },
         initialDraft: String = "", initialAlwaysDraft: String = "")
    {
        self.store = store
        self.layouts = layouts
        self.isFrequent = isFrequent
        draft = State(initialValue: initialDraft)
        alwaysDraft = State(initialValue: initialAlwaysDraft)
    }

    private var words: WordRules { store.settings.words }
    private var validation: WordRules.Validation {
        words.validate(draft.wrappedValue, readings: readings(of: draft.wrappedValue), isFrequent: isFrequent)
    }

    private var alwaysValidation: WordRules.Validation {
        words.validate(alwaysDraft.wrappedValue, for: .always, readings: readings(of: alwaysDraft.wrappedValue))
    }

    private func readings(of word: String) -> [String] { WordRules.readings(of: word, in: layouts) }

    var body: some View {
        PKPane(title: Text("Words")) {
            Text("Perekey never touches the first two lists and always fixes the third, in any layout.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
            mineSection
            learnedSection
            alwaysSection
        }
    }

    private var mineSection: some View {
        PKGroup(header: Text("Don't touch: mine") + Text(count(words.mine.count)).foregroundStyle(Color.pkInk3)) {
            HStack(spacing: 8) {
                TextField("Word", text: draft.projectedValue, prompt: Text("Add a word"))
                    .labelsHidden()
                    .pkField()
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.pkPrimary)
                    .disabled(![.ok, .frequent].contains(validation))
            }
            .padding(PK.Space.md)
            if let message = message {
                PKCallout(Text(message.text), symbol: message.symbol, tone: .warn, quiet: !message.warning)
            }
            if words.mine.isEmpty {
                PKDivider()
                PKNote(Text("No words yet."))
            }
            VStack(spacing: 0) {
                ForEach(words.mine, id: \.self) { word in
                    VStack(spacing: 0) {
                        PKDivider()
                        PKRow(Text(word)) {
                            Button("Remove") { store.update { $0.words.remove(word) } }
                                .buttonStyle(.pkLink)
                        }
                        .pkFound("mine:" + word, tracker: found.wrappedValue)
                    }
                    .pkRowTransition()
                }
            }
            .pkListChanges(words.mine)
            .onChange(of: words.mine) { old, new in
                for word in new where !old.contains(word) { found.wrappedValue.mark("mine:" + word) }
            }
        }
    }

    private var learnedSection: some View {
        PKGroup(header: Text("Don't touch: learned") + Text(count(words.learned.count)).foregroundStyle(Color.pkInk3)) {
            PKRow(Text("Learn from undone corrections")) {
                Toggle("Learn from undone corrections", isOn: learnBinding)
                    .labelsHidden()
                    .toggleStyle(.pkSwitch)
            }
            if words.learned.isEmpty {
                PKDivider()
                PKNote(Text("Words you undo after a correction appear here."))
            }
            VStack(spacing: 0) {
                ForEach(words.learned, id: \.word) { item in
                    VStack(spacing: 0) {
                        PKDivider()
                        PKRow(Text(item.word)) {
                            HStack(spacing: 12) {
                                if item.undoCount > 1 {
                                    Text("undone \(item.undoCount) times")
                                        .font(PK.Font.caption)
                                        .foregroundStyle(Color.pkInk2)
                                }
                                Text(Date(timeIntervalSince1970: item.lastUndoneAt).formatted(date: .abbreviated, time: .omitted))
                                    .font(PK.Font.caption)
                                    .foregroundStyle(Color.pkInk2)
                                Button("Forget") { store.update { $0.words.forget(item.word) } }
                                    .buttonStyle(.pkLink)
                            }
                        }
                        .pkFound("learned:" + item.word, tracker: found.wrappedValue)
                    }
                    .pkRowTransition()
                }
            }
            .pkListChanges(words.learned.map(\.word))
            .onChange(of: words.learned.map(\.word)) { old, new in
                for word in new where !old.contains(word) { found.wrappedValue.mark("learned:" + word) }
            }
            if !words.learned.isEmpty {
                PKDivider()
                PKRow(Text(verbatim: "")) {
                    Button("Forget all") { store.update { $0.words.forgetAllLearned() } }
                        .buttonStyle(.pkSecondary)
                }
            }
        }
    }

    private var alwaysSection: some View {
        PKGroup(header: Text("Always fix") + Text(count(words.always.count)).foregroundStyle(Color.pkInk3)) {
            HStack(spacing: 8) {
                TextField("Word", text: alwaysDraft.projectedValue, prompt: Text("The word as it should come out"))
                    .labelsHidden()
                    .pkField()
                    .onSubmit(addAlways)
                Button("Add", action: addAlways)
                    .buttonStyle(.pkPrimary)
                    .disabled(alwaysValidation != .ok)
            }
            .padding(PK.Space.md)
            if let message = alwaysMessage {
                PKCallout(message.text, symbol: message.symbol, tone: .warn, quiet: true)
            }
            if words.always.isEmpty {
                PKDivider()
                PKNote(Text("Typed in the other layout, these words switch after a space even when Perekey is unsure. Passwords, code and digits stay as typed."))
            }
            VStack(spacing: 0) {
                ForEach(words.always, id: \.self) { word in
                    VStack(spacing: 0) {
                        PKDivider()
                        PKRow(Text(word)) {
                            Button("Remove") { store.update { $0.words.stopFixing(word) } }
                                .buttonStyle(.pkLink)
                        }
                        .pkFound("always:" + word, tracker: found.wrappedValue)
                    }
                    .pkRowTransition()
                }
            }
            .pkListChanges(words.always)
            .onChange(of: words.always) { old, new in
                for word in new where !old.contains(word) { found.wrappedValue.mark("always:" + word) }
            }
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
        let readings = readings(of: word)
        store.update { $0.words.add(word, readings: readings) }
        draft.wrappedValue = ""
    }

    private func addAlways() {
        guard alwaysValidation == .ok else { return }
        let word = alwaysDraft.wrappedValue
        let readings = readings(of: word)
        store.update { $0.words.alwaysFix(word, readings: readings) }
        alwaysDraft.wrappedValue = ""
    }

    private var message: (text: LocalizedStringKey, symbol: String, warning: Bool)? {
        switch validation {
        case .ok, .empty: nil
        case .invalid: ("Use one word: letters, apostrophe and hyphen.", "xmark.circle", false)
        case .duplicate, .neverTouch, .tooShort: ("This word is already on a list.", "info.circle", false)
        case .frequent: ("This word will stop being corrected everywhere.", "exclamationmark.triangle.fill", true)
        }
    }

    private var alwaysMessage: (text: Text, symbol: String)? {
        switch alwaysValidation {
        case .ok, .empty, .frequent: nil
        case .invalid: (Text("Use one word: letters, apostrophe and hyphen."), "xmark.circle")
        case .tooShort: (Text("Use a word of 3 letters or more: shorter ones are too often meant as typed."), "info.circle")
        case .duplicate, .neverTouch: (Text("This word is already on a list."), "info.circle")
        }
    }
}
