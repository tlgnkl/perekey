// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// What a style looks like in the menu bar for the current layout, as a plain
/// value: the picker tiles and the snapshots draw it, the live item adds motion.
@MainActor
struct MenuBarPreview {
    var code = "EN"
    var icon: NSImage?

    init(sources: InputSources?) {
        guard let sources, let current = sources.currentLayout else { return }
        code = sources.indicator(of: current)
        icon = sources.icon(of: current)
    }

    init(code: String, icon: NSImage? = nil) {
        self.code = code
        self.icon = icon
    }

    @ViewBuilder func glyph(_ style: MenuBarIconStyle, dark: Bool) -> some View {
        let model = CapsuleModel(code: code)
        if style == .capsule {
            CapsuleView(model: model, dark: dark, height: 16, fontSize: 9.5)
        } else {
            MenuBarGlyph(style: style, model: model, icon: icon)
        }
    }
}

/// A 78x50 picker tile: a mini menu bar with the item, and the label under it.
private struct MenuBarStyleTile: View {
    let style: MenuBarIconStyle
    let title: Text
    let preview: MenuBarPreview
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.pkWash)
                    HStack {
                        Spacer(minLength: 0)
                        preview.glyph(style, dark: scheme == .dark).scaleEffect(0.85)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.07))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
                }
                .frame(width: 78, height: 50)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.pkIndigo, lineWidth: 2.5)
                    }
                }
                title.font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.pkInk : Color.pkInk2)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Settings → General → «Menu bar»: how the item looks, when it shows, and a
/// note when the system's input menu and Perekey show the language twice or
/// not at all.
struct MenuBarGroup: View {
    let store: SettingsStore
    var sources: InputSources?
    var systemMenu: SystemInputMenu = .shared

    private var style: MenuBarIconStyle { store.settings.menuBarIcon }
    private var visibility: MenuBarVisibility { store.settings.menuBarVisibility }

    var body: some View {
        PKGroup(header: Text("Menu bar")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Icon").font(PK.Font.body).foregroundStyle(Color.pkInk)
                HStack(alignment: .top, spacing: 12) {
                    tile(.capsule, Text("Capsule"))
                    tile(.letters, Text("Letters"))
                    tile(.system, Text("System icon"))
                    tile(.mark, Text("Mark"))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, PK.Space.lg)
            .padding(.vertical, 12)
            .accessibilityElement(children: .contain)
            PKDivider()
            PKRow(Text("Show the icon"),
                  detail: visibility == .never
                      ? Text("To bring it back, open Perekey again: from Finder, Spotlight or Launchpad.")
                      : Text("“When there is news” means a pause, automatic switching off, or a call being recorded.")) {
                PKSegmented(items: [
                    .init(value: MenuBarVisibility.always, label: Text("Always")),
                    .init(value: .whenNeeded, label: Text("When there is news")),
                    .init(value: .never, label: Text("Never")),
                ], selection: Binding(get: { visibility }, set: { value in
                    store.update { $0.menuBarVisibility = value }
                }), mini: true)
            }
            notice
        }
        .onAppear { systemMenu.refresh() }
    }

    private func tile(_ value: MenuBarIconStyle, _ title: Text) -> some View {
        MenuBarStyleTile(style: value, title: title, preview: MenuBarPreview(sources: sources), selected: style == value) {
            store.update { $0.menuBarIcon = value }
        }
    }

    @ViewBuilder private var notice: some View {
        switch MenuBarPolicy.notice(style: style, visibility: visibility, systemMenuVisible: systemMenu.visible) {
        case .shownTwice:
            PKDivider()
            PKCallout(Text("The language is shown twice: by the system input menu and by Perekey."),
                      symbol: "info.circle.fill", quiet: true)
            PKRow(Text("In System Settings turn off “Show Input menu in menu bar”."), detail: nil) {
                Button("Open Keyboard Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.pkSecondary)
            }
        case .notShown:
            PKDivider()
            PKCallout(Text("The layout is not shown in the menu bar now."))
            PKRow(Text("Show the layout in Perekey"), detail: nil) {
                Button("Show the capsule") {
                    store.update {
                        $0.menuBarIcon = .capsule
                        $0.menuBarVisibility = .always
                    }
                }
                .buttonStyle(.pkSecondary)
            }
        case nil:
            EmptyView()
        }
    }
}
