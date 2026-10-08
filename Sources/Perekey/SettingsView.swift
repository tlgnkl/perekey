// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The Settings window: one tab per pane.
struct SettingsView: View {
    let store: SettingsStore
    let recording: ShortcutRecording

    var body: some View {
        TabView {
            Form {
                Text("General settings are coming soon.")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            ShortcutsPane(store: store, recording: recording)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 560)
        .onDisappear { recording.stop() }
    }
}
