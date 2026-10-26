// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Privacy: what Perekey stores and sends, what it never touches, the
/// opt-in counters, the settings file and the report form.
struct PrivacyPane: View {
    let store: SettingsStore
    /// Names of the enabled layouts, for the report.
    let layoutNames: [String]
    /// `nil` hides the statistics section (it needs the recorder).
    let usage: UsageRecorder?
    /// `nil` hides the row about the languages of apps.
    let languages: LanguageStatsStore?

    private let reporting: State<Bool>

    init(store: SettingsStore, usage: UsageRecorder? = nil, languages: LanguageStatsStore? = nil,
         layoutNames: [String] = [], isReporting: Bool = false)
    {
        self.store = store
        self.usage = usage
        self.languages = languages
        self.layoutNames = layoutNames
        reporting = State(initialValue: isReporting)
    }

    var body: some View {
        PKPane(title: Text("Privacy")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Typed text is never saved and never leaves this Mac. Files on this Mac: settings.json (settings and your word lists, with dates and undo counts), statistics.json (only with “Count corrections” on: counts, no words), languages.json (how many words of each language per app: app IDs and counts). Site counts stay in memory.")
                networkNote
            }
            .font(PK.Font.body)
            .foregroundStyle(Color.pkInk2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            guaranteesSection
            if let usage { statisticsSection(usage) }
            if let languages { languagesSection(languages) }
            PKGroup(header: Text("Settings file"), anchor: "privacy.file") {
                PKRow(Text("Back up or move settings"), detail: Text("Shortcuts, apps and words as a JSON file."),
                      anchor: "privacy.backup") {
                    HStack(spacing: 8) {
                        Button("Export…", action: export)
                        Button("Import…", action: importFile)
                    }
                    .buttonStyle(.pkSecondary)
                }
            }
            PKGroup(header: Text("Feedback"), anchor: "privacy.feedback") {
                PKRow(Text("A wrong correction?"), detail: Text("You see the text before anything is sent."),
                      anchor: "privacy.report") {
                    Button("Report a word…") { reporting.wrappedValue = true }
                        .buttonStyle(.pkSecondary)
                }
            }
            .sheet(isPresented: reporting.projectedValue) {
                ReportWordSheet(layouts: layoutNames, version: ReportContext.version, onOpen: { url in
                    NSWorkspace.shared.open(url)
                    reporting.wrappedValue = false
                }, onCancel: { reporting.wrappedValue = false })
            }
        }
    }

    /// Opt-in counters. The week shows only while they are on.
    private func statisticsSection(_ usage: UsageRecorder) -> some View {
        _ = usage.revision
        return PKGroup(header: Text("Statistics"), anchor: "privacy.statistics") {
            PKRow(Text("Count corrections"),
                  detail: Text("Perekey keeps a count per day on this Mac: how many corrections, of which kind, how many you undid. No words, no apps. It keeps 8 weeks."),
                  anchor: "privacy.count") {
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
                // search: skip (shown only in some states)
                PKRow(Text("Erase the counts"), detail: Text("Deletes the file with the counts.")) {
                    Button("Erase") { usage.erase() }
                        .buttonStyle(.pkSecondary)
                        .disabled(usage.stats.isEmpty)
                }
            }
        }
    }

    /// The language counts per app (`LanguageStats`): always on, so they
    /// are named here with a way to erase them.
    private func languagesSection(_ languages: LanguageStatsStore) -> some View {
        PKGroup(header: Text("Languages of apps"), anchor: "privacy.languages") {
            PKRow(Text("Forget the languages of apps"),
                  detail: Text("To guess the language of the next word, Perekey counts how many words in each language you type in an app. No words, only counts. Sites are counted only until you quit."),
                  anchor: "privacy.forget-languages") {
                Button("Erase") { languages.resetAll() }
                    .buttonStyle(.pkSecondary)
                    .disabled(languages.stats.apps.isEmpty && languages.stats.sites.isEmpty)
            }
        }
    }

    /// What the network is used for. A build with voice input has more reasons than the update check.
    private var networkNote: Text {
        #if PEREKEY_VOICE
        voiceText("Speech models run on this Mac. The network is used for the update check and for what you start yourself: downloading a speech model, and a server you set up for a voice mode.")
        #else
        Text("The only network request is the update check.")
        #endif
    }

    /// What Perekey never changes. Statements, not settings: no controls.
    private var guaranteesSection: some View {
        PKGroup(header: Text("Perekey does not touch"), anchor: "privacy.guarantees") {
            PKGuaranteeRow(symbol: "lock.fill", Text("Password fields"),
                           detail: Text("Where macOS marks the field as secure, or secure input is on."),
                           sample: "••••••••")
                .pkAnchor("privacy.password-fields")
            PKDivider()
            PKGuaranteeRow(symbol: "key.fill", Text("Strings that look like passwords"),
                           detail: Text("Upper and lower case, digits and symbols mixed together stay as typed."),
                           sample: "Xk9#mQ2v")
                .pkAnchor("privacy.password-like")
            PKDivider()
            PKGuaranteeRow(symbol: "checkmark.shield.fill", Text("Random letters, as in a captcha"),
                           detail: Text("When neither layout makes a word, Perekey does nothing."),
                           sample: "qzkvtp")
                .pkAnchor("privacy.captcha")
            PKDivider()
            PKGuaranteeRow(symbol: "terminal.fill", Text("Code in terminals and editors"),
                           detail: Text("There Perekey acts only on your command."),
                           sample: "git rebase -i")
                .pkAnchor("privacy.code")
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
