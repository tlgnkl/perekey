// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General: sounds, feedback, and export and import of all settings.
struct GeneralPane: View {
    let store: SettingsStore
    /// Names of the enabled layouts, for the report.
    let layoutNames: [String]

    private let reporting: State<Bool>

    init(store: SettingsStore, layoutNames: [String] = [], isReporting: Bool = false) {
        self.store = store
        self.layoutNames = layoutNames
        reporting = State(initialValue: isReporting)
    }

    var body: some View {
        PKPane(title: Text("General")) {
            soundsSection
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
