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
    let appModes: AppModeController
    /// Opens the onboarding window again; `nil` hides the row (snapshots).
    var onShowOnboarding: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let reason = pause.current {
                PauseCard(reason: reason, now: pause.now, onAction: { action(for: reason) })
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            PKDivider(leading: 12, trailing: 12)
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
                if let app = appModes.frontmost {
                    switchRow(
                        title: "Don't switch in \(app.name)",
                        isOn: Binding(get: { appModes.mode == .off }, set: { appModes.setOff($0) })
                    )
                }
                LaunchAtLoginRow(launch: launch)
            }
            .padding(.vertical, 6)
            PKDivider(leading: 12, trailing: 12)
            LayoutsList(sources: sources)
                .padding(.vertical, 6)
            PKDivider(leading: 12, trailing: 12)
            VStack(alignment: .leading, spacing: 0) {
                SettingsLink {
                    MenuRowLabel(title: "Settings…", shortcut: "⌘,")
                }
                .buttonStyle(MenuRowStyle())
                .simultaneousGesture(TapGesture().onEnded { SettingsFront.raise() })
                .keyboardShortcut(",")
                if let onShowOnboarding {
                    Button(action: onShowOnboarding) {
                        MenuRowLabel(title: "Show Onboarding…", shortcut: nil)
                    }
                    .buttonStyle(MenuRowStyle())
                }
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
                dark: colorScheme == .dark, height: 30, fontSize: 17, animated: true
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(sources.currentLayout.map(sources.name(of:)) ?? String(localized: "No layout"))
                    .font(PK.Font.headline)
                    .foregroundStyle(Color.pkInk)
                Text(store.settings.autoswitch ? String(localized: "Automatic switching is on") : String(localized: "Automatic switching is off"))
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous), glow: false)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
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
            HatchTile(symbol: reason.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(reason.title(now: now)).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
                Text(reason.detail)
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = reason.actionTitle {
                    Button(title, action: onAction)
                        .buttonStyle(.pkSmall)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pkCard()
        .accessibilityElement(children: .combine)
    }
}

/// A title on the left and its switch on the right.
struct SwitchLine: View {
    let title: LocalizedStringKey
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            Text(title).font(PK.Font.body).foregroundStyle(Color.pkInk)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.pkSwitch)
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
                        .font(PK.Font.caption)
                        .foregroundStyle(Color.pkInk2)
                    Button("Open Settings") { launch.openSystemSettings() }
                        .buttonStyle(.pkSmall)
                }
            } else if !launch.isAvailable {
                Text("Works in the installed app only.")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
            }
            if let error = launch.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkWarn)
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
                        Text(sources.name(of: layout.id)).font(PK.Font.body)
                        Spacer()
                        if sources.currentLayout == layout.id {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
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
            Text(title).font(PK.Font.body)
            Spacer()
            if let shortcut { Text(shortcut).font(PK.Font.body).opacity(0.55) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Row with the Solid Indigo Fill hover and white text from the menu spec.
/// Inset 6pt from the edge with an 8pt radius, like a native menu item.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable(configuration: configuration)
    }

    private struct Hoverable: View {
        let configuration: Configuration
        private let hovering = State(initialValue: false)

        var body: some View {
            let hot = hovering.wrappedValue
            configuration.label
                .foregroundStyle(hot ? Color.white : Color.pkInk)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hot ? Color.pkIndigoFill : .clear))
                .padding(.horizontal, 6)
                .onHover { hovering.wrappedValue = $0 }
                .pkAnimation(.easeOut(duration: 0.1), value: hot)
        }
    }
}
