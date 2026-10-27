// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import PerekeyInput
import PerekeyVoiceCore
import SwiftUI

/// The last dictations in the menu: «Copy» and «Paste again» for each, and the
/// switch that shows their text. The history decides what is in it: nothing
/// from password fields or excluded apps is there to show.
struct DictationMenuSection: View {
    let menu: DictationMenu
    var close: () -> Void = {}

    private static let visibleRows: CGFloat = 4

    var body: some View {
        let history = menu.history
        let entries = history.recent(20)
        let shows = menu.text.settings.showsTextInMenu
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                voiceText("Recent dictations").font(PK.Font.captionStrong).foregroundStyle(Color.pkInk2)
                Spacer()
                Toggle(isOn: Binding(get: { shows }, set: { on in menu.text.update { $0.showsTextInMenu = on } })) {
                    voiceText("Show text")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(PK.Font.caption)
                .foregroundStyle(Color.pkInk2)
            }
            .padding(.horizontal, 4)
            ScrollView {
                VStack(spacing: 4) {
                    if let unsaved = history.unsaved {
                        row(unsaved, shows: shows, note: "Not saved. Kept until Perekey quits.")
                    }
                    ForEach(entries) { entry in
                        row(entry, shows: shows)
                    }
                }
            }
            .frame(maxHeight: Self.visibleRows * 56)
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func row(_ entry: HistoryEntry, shows: Bool, note: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: shows ? DictationHistoryText.preview(entry.text) : (entry.appName ?? "—"))
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk)
                .lineLimit(1)
            HStack(spacing: 8) {
                Group {
                    if let note { voiceText(note) } else { Text(verbatim: caption(entry)) }
                }
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk3)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(Text(verbatim: entry.appName ?? ""))
                Spacer(minLength: 4)
                Button { menu.copy(entry) } label: { voiceText("Copy").font(PK.Font.caption) }
                    .buttonStyle(.pkLink)
                    .fixedSize()
                if let pasteAgain = menu.pasteAgain {
                    Button { close(); pasteAgain(entry) } label: { voiceText("Paste again").font(PK.Font.caption) }
                        .buttonStyle(.pkLink)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func caption(_ entry: HistoryEntry) -> String {
        let when = Calendar.current.isDateInToday(entry.date)
            ? entry.date.formatted(date: .omitted, time: .shortened)
            : entry.date.formatted(date: .abbreviated, time: .shortened)
        return when
    }
}
#endif
