// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import ServiceManagement
import SwiftUI

/// What the capsule shows for the current layout, settings and pause state.
@MainActor
func capsuleModel(sources: InputSources, store: SettingsStore, pause: PauseState) -> CapsuleModel {
    CapsuleModel(
        code: sources.currentLayout.map(sources.indicator(of:)) ?? "⌨",
        struck: !store.settings.autoswitch,
        reason: pause.current,
        now: pause.now
    )
}

/// The menu bar label; a separate view so it can read the color scheme.
struct MenuBarLabel: View {
    let sources: InputSources
    let store: SettingsStore
    let pause: PauseState

    var body: some View {
        CapsuleLabel(model: capsuleModel(sources: sources, store: store, pause: pause))
    }
}

/// The popover (`.menuBarExtraStyle(.window)`): header, pause card, switches,
/// layouts, Settings and Quit. Structure follows `pmenu` in `design/mockup.html`;
/// stage 1 uses plain system styling.
struct MenuContent: View {
    let sources: InputSources
    let store: SettingsStore
    let pause: PauseState
    let launch: LaunchAtLogin

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let reason = pause.current {
                PauseCard(reason: reason, now: pause.now, onAction: { action(for: reason) })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                switchRow(
                    title: "Automatic switching",
                    isOn: Binding(
                        get: { store.settings.autoswitch },
                        set: { value in store.update { $0.autoswitch = value } }
                    )
                )
                switchRow(
                    title: "Pause for 1 hour",
                    isOn: Binding(
                        get: { pause.isTimedPauseActive },
                        set: { $0 ? pause.pauseForOneHour() : pause.resumeTimed() }
                    )
                )
                LaunchAtLoginRow(launch: launch)
            }
            .padding(.vertical, 6)
            Divider()
            LayoutsList(sources: sources)
                .padding(.vertical, 6)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                SettingsLink {
                    MenuRowLabel(title: "Settings…", shortcut: "⌘,")
                }
                .buttonStyle(MenuRowStyle())
                .keyboardShortcut(",")
                Button { NSApplication.shared.terminate(nil) } label: {
                    MenuRowLabel(title: "Quit Perekey", shortcut: "⌘Q")
                }
                .buttonStyle(MenuRowStyle())
                .keyboardShortcut("q")
            }
            .padding(.vertical, 6)
        }
        .frame(width: 318)
        // `.task` is cancelled when the menu closes, so the minutes refresh only
        // while someone can see them.
        .task {
            pause.tick()
            launch.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                pause.tick()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CapsuleView(
                model: CapsuleModel(code: sources.currentLayout.map(sources.indicator(of:)) ?? "⌨", struck: !store.settings.autoswitch),
                dark: colorScheme == .dark, height: 30, fontSize: 17
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(sources.currentLayout.map(sources.name(of:)) ?? "No layout")
                    .font(.headline)
                Text(store.settings.autoswitch ? "Automatic switching is on" : "Automatic switching is off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func switchRow(title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        SwitchLine(title: title, isOn: isOn)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
    }

    private func action(for reason: PauseReason) {
        switch reason {
        case .timed: pause.resumeTimed()
        case .appOff: pause.onTurnOnHere?()
        case .secureInput, .passwordField: break
        }
    }
}

/// The card for the active pause reason, with its action when the user can end it here.
struct PauseCard: View {
    let reason: PauseReason
    let now: Date
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: reason.symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Text(reason.title(now: now)).font(.subheadline.weight(.semibold))
                Text(reason.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = reason.actionTitle {
                    Button(title, action: onAction)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1)))
    }
}

/// A title on the left and its switch on the right.
struct SwitchLine: View {
    let title: LocalizedStringKey
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// The "Launch at login" switch with the states `SMAppService` can be in.
struct LaunchAtLoginRow: View {
    let launch: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SwitchLine(title: "Launch at login", isOn: Binding(get: { launch.isOn }, set: { launch.setEnabled($0) }))
                .disabled(!launch.isAvailable)
            if launch.status == .requiresApproval {
                HStack(spacing: 6) {
                    Text("Approve Perekey in Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") { launch.openSystemSettings() }
                        .controlSize(.small)
                }
            } else if !launch.isAvailable {
                Text("Works in the installed app only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = launch.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}

/// The enabled layouts with a checkmark on the selected one; a click selects.
/// Same idea as `LayoutsMenu`, drawn as rows because a window popover is not a menu.
struct LayoutsList: View {
    let sources: InputSources

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.layouts, id: \.id) { layout in
                Button { sources.select(layout.id) } label: {
                    HStack {
                        Text(sources.name(of: layout.id))
                        Spacer()
                        if sources.currentLayout == layout.id {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MenuRowStyle())
            }
        }
    }
}

struct MenuRowLabel: View {
    let title: LocalizedStringKey
    var shortcut: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Row with the Solid Indigo Fill hover and white text from the menu spec.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable(configuration: configuration)
    }

    private struct Hoverable: View {
        let configuration: Configuration
        private let hovering = State(initialValue: false)

        var body: some View {
            configuration.label
                .foregroundStyle(hovering.wrappedValue ? Color.white : Color.primary)
                .background(hovering.wrappedValue ? Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255) : .clear)
                .onHover { hovering.wrappedValue = $0 }
        }
    }
}
