// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI
import UniformTypeIdentifiers

/// Settings → General. For now: export and import of all settings.
struct GeneralPane: View {
    let store: SettingsStore

    var body: some View {
        Form {
            Section("Settings file") {
                LabeledContent {
                    HStack {
                        Button("Export…", action: export)
                        Button("Import…", action: importFile)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back up or move settings")
                        Text("Shortcuts, apps and words as a JSON file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
