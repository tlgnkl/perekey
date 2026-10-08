// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyInput
import SwiftUI

@main
struct PerekeyApp: App {
    // A plain `let`: the App value is created once, and the `@State` macro plugin
    // is missing from Command Line Tools.
    private let inputSources = InputSources()

    init() {
        // Menu bar only, no Dock icon. The bundled Info.plist sets LSUIElement too;
        // this keeps `swift run` behaving the same way.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            Text("Perekey \(Bundle.main.shortVersion)")
            Divider()
            LayoutsMenu(sources: inputSources)
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Button("Quit Perekey") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Text(inputSources.currentLayout.map(inputSources.indicator(of:)) ?? "⌨")
        }

        Settings {
            SettingsView()
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Nothing to configure yet.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 200)
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
