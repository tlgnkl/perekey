// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyInput
import SwiftUI

/// The Settings window: one tab per pane.
struct SettingsView: View {
    let store: SettingsStore
    let recording: ShortcutRecording
    let sources: InputSources

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

            AppsPane(store: store, sources: sources)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
        }
        .frame(width: 560, height: 560)
        .onDisappear { recording.stop() }
    }
}
