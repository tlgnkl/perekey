// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import SwiftUI

/// "Report a word": shows the exact text of a pre-filled GitHub issue before
/// anything leaves the Mac. Perekey sends nothing: the button only opens the
/// link in the browser, where the user can still edit it. The word is in the
/// report only while the user keeps it.
///
/// A hint or a menu item opens it with `initialWord`; Settings → General opens it empty.
struct ReportWordSheet: View {
    let layouts: [String]
    let version: String
    let onOpen: (URL) -> Void
    let onCancel: () -> Void

    private let word: State<String>
    private let keepWord: State<Bool>
    private let did: State<String>
    private let mode: State<FalseSwitchReport.Mode>

    init(initialWord: String = "", layouts: [String], version: String, onOpen: @escaping (URL) -> Void,
         onCancel: @escaping () -> Void)
    {
        self.layouts = layouts
        self.version = version
        self.onOpen = onOpen
        self.onCancel = onCancel
        word = State(initialValue: initialWord)
        keepWord = State(initialValue: true)
        did = State(initialValue: "")
        mode = State(initialValue: .hotkey)
    }

    /// The report as it stands now; the sheet shows it and opens its link.
    var report: FalseSwitchReport {
        FalseSwitchReport(typed: keepWord.wrappedValue ? word.wrappedValue : "", did: did.wrappedValue,
                          mode: mode.wrappedValue, layouts: layouts, version: version)
    }

    var body: some View {
        let report = report
        VStack(alignment: .leading, spacing: 14) {
            Text("Report a word")
                .font(PK.Font.title)
                .foregroundStyle(Color.pkInk)
                .accessibilityAddTraits(.isHeader)
            Text("Perekey sends nothing by itself. The button opens a GitHub form with the text below; you can still change it there.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)

            PKGroup {
                PKRow(Text("Include the word"), detail: Text("Leave it out if the text is private.")) {
                    Toggle("Include the word", isOn: keepWord.projectedValue)
                        .labelsHidden()
                        .toggleStyle(.pkSwitch)
                }
                HStack(spacing: 8) {
                    TextField("Word", text: word.projectedValue, prompt: Text("The word"))
                        .labelsHidden()
                        .pkField()
                        .disabled(!keepWord.wrappedValue)
                    TextField("What Perekey did", text: did.projectedValue, prompt: Text("What Perekey did"))
                        .labelsHidden()
                        .pkField()
                }
                .padding(PK.Space.md)
                PKDivider()
                PKRow(Text("Mode")) {
                    Picker("Mode", selection: mode.projectedValue) {
                        ForEach(FalseSwitchReport.Mode.allCases, id: \.self) { mode in
                            Text(verbatim: mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }
            }

            PKGroup(header: Text("This is what the link contains")) {
                ForEach(Array(report.fields.enumerated()), id: \.offset) { index, field in
                    if index > 0 { PKDivider() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: field.label).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        Text(verbatim: field.value).font(PK.Font.body).foregroundStyle(Color.pkInk)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PK.Space.lg)
                    .padding(.vertical, 8)
                }
            }

            Text(verbatim: report.url.absoluteString)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.pkInk3)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.pkSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Open on GitHub") { onOpen(report.url) }
                    .buttonStyle(.pkPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PK.Space.pane)
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The version line of a report: "Perekey 0.1 (1), macOS 14.5".
@MainActor
enum ReportContext {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Perekey \(short) (\(build)), macOS \(os.majorVersion).\(os.minorVersion)"
    }
}
