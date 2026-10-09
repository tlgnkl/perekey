// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// Settings → General: corrections, the hint, sounds and updates. What Perekey
/// stores and never touches is in `PrivacyPane`.
struct GeneralPane: View {
    let store: SettingsStore
    let updates: Updates
    /// The enabled layouts: with more than two languages General says which pairs switch by itself.
    var layouts: [LayoutMap] = []

    var body: some View {
        PKPane(title: Text("General")) {
            if LanguagePairs(layouts: layouts).hasChoice {
                LanguagePairsGroup(pairs: LanguagePairs(layouts: layouts), retypeKeys: retypeKeys)
            }
            correctionsSection
            hintSection
            soundsSection
            updatesSection
        }
    }

    /// What Perekey corrects by itself besides the layout, each with its
    /// switch and the mock's example chip. Typos: docs/classifier.md,
    /// «Опечатки»; the rest: docs/corrections.md.
    private var correctionsSection: some View {
        PKGroup(header: Text("Corrections")) {
            PKRow(Text("Correct typos"),
                  detail: Text("Russian and English, one key off. Backspace right after a correction puts the word back.")) {
                HStack(spacing: 12) {
                    PKExampleChip(from: "прривет", to: "привет", isOn: store.settings.typoCorrection)
                    Toggle(isOn: Binding(get: { store.settings.typoCorrection },
                                         set: { on in store.update { $0.typoCorrection = on } })) {
                        Text("Correct typos")
                    }
                    .labelsHidden()
                    .toggleStyle(.pkSwitch)
                }
            }
            PKDivider()
            correctionRow(Text("Double capitals"), example: ("ПРивет", "Привет"), \.doubleCapitals)
            PKDivider()
            correctionRow(Text("Accidental Caps Lock"), detail: Text("Fix the word and turn Caps Lock off"),
                          example: ("пРИВЕТ", "Привет"), \.capsLock)
            PKDivider()
            correctionRow(Text("Abbreviations"), example: ("мвд", "МВД"), \.abbreviations)
            PKDivider()
            correctionRow(Text("Letter ё"), detail: Text("Russian only, where the word with «е» is no other word"),
                          example: ("еще", "ещё"), \.yo)
            PKDivider()
            correctionRow(Text("Retype a phrase"),
                          detail: Text("Press the retype shortcut again: the second press puts the word back, the third retypes two words, and so on."),
                          example: ("ghbdtn vbh", "привет мир"), \.phraseRetype)
        }
    }

    private func correctionRow(_ title: Text, detail: Text? = nil, example: (from: String, to: String),
                               _ key: WritableKeyPath<TextCorrections, Bool>) -> some View
    {
        let isOn = store.settings.corrections[keyPath: key]
        return PKRow(title, detail: detail) {
            HStack(spacing: 12) {
                PKExampleChip(from: example.from, to: example.to, isOn: isOn)
                Toggle(isOn: Binding(get: { isOn }, set: { on in store.update { $0.corrections[keyPath: key] = on } })) {
                    title
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
            }
        }
    }

    private var retypeKeys: String? {
        store.settings.trigger(for: .convertLastWord).map { TriggerText.keycaps(of: $0).joined(separator: " ") }
    }

    private var hintSection: some View {
        PKGroup(header: Text("Hint")) {
            PKRow(Text("Hint at the caret"), detail: Text("Shows what Perekey changed, a moment after the word.")) {
                PKSegmented(items: [
                    .init(value: CaretHintMode.all, label: Text("All edits")),
                    .init(value: .automatic, label: Text("Automatic only")),
                    .init(value: .off, label: Text("Off")),
                ], selection: Binding(get: { store.settings.caretHint }, set: { mode in
                    store.update { $0.caretHint = mode }
                }), mini: true)
            }
        }
    }

    private var soundsSection: some View {
        PKGroup(header: Text("Sounds")) {
            soundRow(Text("Sound on layout switch"), setting: store.settings.layoutSound) { change in
                store.update { change(&$0.layoutSound) }
            }
            PKDivider()
            soundRow(Text("Sound on correction"), setting: store.settings.correctionSound) { change in
                store.update { change(&$0.correctionSound) }
            }
        }
    }

    /// The switch, the last check and "Check Now". A profile turns it all off;
    /// a development build has no key to check updates with.
    private var updatesSection: some View {
        let policy = updates.policy
        return PKGroup(header: Text("Updates")) {
            PKRow(Text("Check for updates automatically"),
                  detail: Text("Once a day Perekey downloads the list of versions from one address. Nothing about you or this Mac is sent.")) {
                Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.setChecksAutomatically($0) })) {
                    Text("Check for updates automatically")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
                .disabled(policy.isLocked)
            }
            PKDivider()
            PKRow(Text("Last check"), detail: lastCheckText) {
                Button("Check Now") { updates.checkNow() }
                    .buttonStyle(.pkSecondary)
                    .disabled(!policy.canCheckNow)
            }
            switch policy.state {
            case .managedOff:
                PKCallout(Text("Managed by your organization. Perekey does not check for updates and makes no network requests."),
                          symbol: "building.2.fill", quiet: true)
            case .notConfigured:
                PKCallout(Text("This build has no update key and cannot update itself."), symbol: "info.circle.fill", quiet: true)
            case .automatic, .manual:
                EmptyView()
            }
        }
    }

    private var lastCheckText: Text {
        guard let date = updates.lastCheck else { return Text("Never") }
        return Text(verbatim: date.formatted(date: .abbreviated, time: .shortened))
    }

    /// A switch, a system sound picker and a play button.
    private func soundRow(_ title: Text, setting: SoundSetting,
                          update: @escaping ((inout SoundSetting) -> Void) -> Void) -> some View
    {
        PKRow(title) {
            HStack(spacing: 8) {
                Picker(selection: Binding(get: { setting.name }, set: { name in
                    update { $0.name = name }
                    SystemSounds.play(named: name)
                })) {
                    // A name from an imported file may not exist on this Mac.
                    ForEach(SystemSounds.names.contains(setting.name) ? SystemSounds.names : [setting.name] + SystemSounds.names,
                            id: \.self) { name in
                        Text(verbatim: name).tag(name)
                    }
                } label: {
                    title
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(!setting.isOn)
                Button { SystemSounds.play(named: setting.name) } label: {
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
                .buttonStyle(.pkSmall)
                .accessibilityLabel(Text("Play"))
                Toggle(isOn: Binding(get: { setting.isOn }, set: { on in update { $0.isOn = on } })) { title }
                    .labelsHidden()
                    .toggleStyle(.pkSwitch)
            }
        }
    }
}
