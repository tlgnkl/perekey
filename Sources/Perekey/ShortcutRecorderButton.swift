// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import SwiftUI

/// Shows the shortcut of one action as keycaps. A click starts recording.
struct ShortcutRecorderButton: View {
    let action: HotkeyAction
    let store: SettingsStore
    let recording: ShortcutRecording

    var body: some View {
        let isRecording = recording.action == action
        VStack(alignment: .trailing, spacing: 2) {
            Button { recording.toggle(action) } label: {
                if isRecording {
                    Text("Press a shortcut…").foregroundStyle(.secondary)
                } else if let trigger = store.settings.trigger(for: action) {
                    HStack(spacing: 4) {
                        ForEach(Array(TriggerText.keycaps(of: trigger).enumerated()), id: \.offset) { _, cap in
                            Keycap(text: cap)
                        }
                    }
                } else {
                    Text("Record")
                }
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if isRecording, let hint = recording.hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        let isWord = text.count > 1 && text != "fn"
        Text(text)
            .font(isWord ? .caption : .body.monospaced())
            .foregroundStyle(isWord ? .secondary : .primary)
    }
}
