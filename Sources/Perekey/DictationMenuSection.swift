// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import PerekeyInput
import PerekeyVoiceCore
import SwiftUI

/// The last dictations in the menu, a line each: the text, the time, and the
/// buttons «Copy» and «Paste again». The eye in the title shows or hides the
/// text. The history decides what is in it: nothing from password fields or
/// excluded apps is there to show.
struct DictationMenuSection: View {
    let menu: DictationMenu
    let nav: MenuNav
    /// How many stored dictations show: 0, 3 or 5. The unsaved one shows whatever the number.
    var rows = 3
    var close: () -> Void = {}

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        let history = menu.history
        let entries = history.recent(rows)
        let shows = menu.text.settings.showsTextInMenu
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                voiceText("Recent dictations").font(PK.Font.captionStrong).foregroundStyle(Color.pkInk2)
                Spacer()
                RowIconButton(id: "dictation-text", symbol: shows ? "eye" : "eye.slash", title: "Show text", table: "Voice",
                              nav: nav, selected: shows) {
                    menu.text.update { $0.showsTextInMenu = !shows }
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 4)
            VStack(spacing: 4) {
                if let unsaved = history.unsaved {
                    row(unsaved, shows: shows, note: voiceText("Not saved: gone when Perekey quits."))
                }
                ForEach(entries) { entry in
                    row(entry, shows: shows)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func row(_ entry: HistoryEntry, shows: Bool, note: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            line(entry, shows: shows)
            // A second line for the unsaved one only.
            if let note {
                note
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(shape.fill(Color.pkRow).overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5)))
        .accessibilityElement(children: .contain)
    }

    private func line(_ entry: HistoryEntry, shows: Bool) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: shows ? DictationHistoryText.preview(entry.text) : (entry.appName ?? "—"))
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: entry.appName ?? ""))
            Spacer(minLength: 2)
            Text(verbatim: when(entry))
                .font(PK.Font.caption)
                .foregroundStyle(Color.pkInk3)
                .lineLimit(1)
                .fixedSize()
            RowIconButton(id: "dictation-\(entry.id)-copy", symbol: "doc.on.doc", title: "Copy", table: "Voice", nav: nav) {
                menu.copy(entry)
            }
            if let pasteAgain = menu.pasteAgain {
                RowIconButton(id: "dictation-\(entry.id)-paste", symbol: "arrow.uturn.down", title: "Paste again",
                              table: "Voice", nav: nav) {
                    close()
                    pasteAgain(entry)
                }
            }
        }
    }

    /// The time of today's dictation, the date of an older one.
    private func when(_ entry: HistoryEntry) -> String {
        Calendar.current.isDateInToday(entry.date)
            ? entry.date.formatted(date: .omitted, time: .shortened)
            : entry.date.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
