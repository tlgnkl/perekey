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
                    ForEach(entries) { entry in
                        row(entry, shows: shows)
                    }
                }
            }
            .frame(maxHeight: Self.visibleRows * 46)
            .scrollIndicators(.automatic)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private func row(_ entry: HistoryEntry, shows: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: shows ? DictationHistoryText.preview(entry.text) : (entry.appName ?? "—"))
                    .font(PK.Font.body)
                    .foregroundStyle(Color.pkInk)
                    .lineLimit(1)
                Text(verbatim: caption(entry, shows: shows))
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { menu.copy(entry) } label: { voiceText("Copy") }
                .buttonStyle(.pkSmall)
            if let pasteAgain = menu.pasteAgain {
                Button { close(); pasteAgain(entry) } label: { voiceText("Paste again") }
                    .buttonStyle(.pkSmall)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private func caption(_ entry: HistoryEntry, shows: Bool) -> String {
        let when = entry.date.formatted(.relative(presentation: .named))
        guard shows, let app = entry.appName else { return when }
        return app + " · " + when
    }
}
#endif
