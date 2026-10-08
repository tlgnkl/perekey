// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General: sounds, updates, feedback, and export and import of all settings.
struct GeneralPane: View {
    let store: SettingsStore
    let updates: Updates
    /// Names of the enabled layouts, for the report.
    let layoutNames: [String]
    /// `nil` hides the statistics section (it needs the recorder).
    let usage: UsageRecorder?

    private let reporting: State<Bool>

    init(store: SettingsStore, updates: Updates, usage: UsageRecorder? = nil, layoutNames: [String] = [],
         isReporting: Bool = false) {
        self.usage = usage
        self.store = store
        self.updates = updates
        self.layoutNames = layoutNames
        reporting = State(initialValue: isReporting)
    }

    var body: some View {
        PKPane(title: Text("General")) {
            correctionsSection
            hintSection
            soundsSection
            updatesSection
            guaranteesSection
            if let usage { statisticsSection(usage) }
            PKGroup(header: Text("Feedback")) {
                PKRow(Text("A wrong correction?"), detail: Text("You see the text before anything is sent.")) {
                    Button("Report a word…") { reporting.wrappedValue = true }
                        .buttonStyle(.pkSecondary)
                }
            }
            PKGroup(header: Text("Settings file")) {
                PKRow(Text("Back up or move settings"), detail: Text("Shortcuts, apps and words as a JSON file.")) {
                    HStack(spacing: 8) {
                        Button("Export…", action: export)
                        Button("Import…", action: importFile)
                    }
                    .buttonStyle(.pkSecondary)
                }
            }
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

    /// Opt-in counters. The week shows only while they are on.
    private func statisticsSection(_ usage: UsageRecorder) -> some View {
        PKGroup(header: Text("Statistics")) {
            PKRow(Text("Count corrections"),
                  detail: Text("Perekey keeps a count per day on this Mac: how many corrections, of which kind, how many you undid. No words, no apps. It keeps 8 weeks.")) {
                Toggle(isOn: Binding(get: { store.settings.statistics }, set: { on in
                    store.update { $0.statistics = on }
                    if on { usage.enabled() }
                })) {
                    Text("Count corrections")
                }
                .labelsHidden()
                .toggleStyle(.pkSwitch)
            }
            if store.settings.statistics {
                PKDivider()
                UsageWeekView(stats: usage.stats)
                PKDivider()
                PKRow(Text("Erase the counts"), detail: Text("Deletes the file with the counts.")) {
                    Button("Erase") { usage.erase() }
                        .buttonStyle(.pkSecondary)
                        .disabled(usage.stats.isEmpty)
                }
            }
        }
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

    /// What Perekey never changes. Statements, not settings: no controls.
    private var guaranteesSection: some View {
        PKGroup(header: Text("Perekey does not touch")) {
            PKGuaranteeRow(symbol: "lock.fill", Text("Password fields"),
                           detail: Text("Where macOS marks the field as secure, or secure input is on."),
                           sample: "••••••••")
            PKDivider()
            PKGuaranteeRow(symbol: "key.fill", Text("Strings that look like passwords"),
                           detail: Text("Upper and lower case, digits and symbols mixed together stay as typed."),
                           sample: "Xk9#mQ2v")
            PKDivider()
            PKGuaranteeRow(symbol: "checkmark.shield.fill", Text("Random letters, as in a captcha"),
                           detail: Text("When neither layout makes a word, Perekey does nothing."),
                           sample: "qzkvtp")
            PKDivider()
            PKGuaranteeRow(symbol: "terminal.fill", Text("Code in terminals and editors"),
                           detail: Text("There Perekey acts only on your command."),
                           sample: "git rebase -i")
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
        .sheet(isPresented: reporting.projectedValue) {
            ReportWordSheet(layouts: layoutNames, version: ReportContext.version, onOpen: { url in
                NSWorkspace.shared.open(url)
                reporting.wrappedValue = false
            }, onCancel: { reporting.wrappedValue = false })
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

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Perekey settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsTransfer.export(store.settings).write(to: url, options: .atomic)
        } catch {
            showError(String(localized: "Cannot export settings"), error)
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let imported: AppSettings
        do {
            imported = try SettingsTransfer.importSettings(from: Data(contentsOf: url))
        } catch {
            showError(String(localized: "Cannot import settings"), error)
            return
        }
        let summary = SettingsTransfer.Summary(imported)
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace your settings?")
        alert.informativeText = Self.summaryText(summary)
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.replaceAll(with: imported)
    }

    static func summaryText(_ summary: SettingsTransfer.Summary) -> String {
        let lead = String(localized: "The file has \(summary.shortcuts) shortcuts, \(summary.apps) apps and \(summary.words) words.")
        return lead + " " + String(localized: "They replace all your current settings.")
    }

    private func showError(_ title: String, _ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
