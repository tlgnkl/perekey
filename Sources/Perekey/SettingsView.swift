// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// The sidebar sections of the Settings window.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case general, shortcuts, apps, sites, words, privacy

    var id: Int { rawValue }

    var title: Text {
        switch self {
        case .general: Text("General")
        case .shortcuts: Text("Shortcuts")
        case .apps: Text("Apps")
        case .sites: Text("Sites")
        case .words: Text("Words")
        case .privacy: Text("Privacy")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard.fill"
        case .apps: "square.grid.2x2.fill"
        case .sites: "globe"
        case .words: "text.badge.xmark"
        case .privacy: "lock.fill"
        }
    }

    /// Multi-hue tiles are the System Settings idiom; they stay in the sidebar.
    var tile: [Color] {
        switch self {
        case .general: [Color(white: 0.62), Color(white: 0.45)]
        case .shortcuts: [Color(red: 0.55, green: 0.53, blue: 1), Color(red: 0.36, green: 0.34, blue: 0.9)]
        case .apps: [Color(red: 0.30, green: 0.62, blue: 1), Color(red: 0.12, green: 0.40, blue: 0.85)]
        case .sites: [Color(red: 0.25, green: 0.78, blue: 0.72), Color(red: 0.08, green: 0.58, blue: 0.55)]
        case .words: [Color(red: 1, green: 0.62, blue: 0.30), Color(red: 0.90, green: 0.42, blue: 0.10)]
        case .privacy: [Color(red: 0.30, green: 0.80, blue: 0.45), Color(red: 0.14, green: 0.54, blue: 0.24)]
        }
    }
}

/// The Settings window: a glass sidebar with one sliding selection strip, and
/// the pane for the current section.
struct SettingsView: View {
    let store: SettingsStore
    let recording: ShortcutRecording
    let sources: InputSources
    let updates: Updates
    let usage: UsageRecorder?
    private let selection: State<SettingsSection>
    private let direction = State(initialValue: 1)
    /// Material behind the whole window; off for offscreen snapshots.
    private let windowBackground: Bool

    init(store: SettingsStore, recording: ShortcutRecording, sources: InputSources, updates: Updates,
         usage: UsageRecorder? = nil, initial: SettingsSection = .general, windowBackground: Bool = true) {
        self.usage = usage
        self.windowBackground = windowBackground
        self.updates = updates
        self.store = store
        self.recording = recording
        self.sources = sources
        selection = State(initialValue: initial)
    }

    private var current: SettingsSection { selection.wrappedValue }

    /// 640pt, but never taller than the visible screen minus 150pt, and never under 560pt.
    private var height: CGFloat {
        Self.windowHeight(visibleScreen: (SettingsFront.window?.screen ?? NSScreen.main)?.visibleFrame.height)
    }

    static func windowHeight(visibleScreen: CGFloat?) -> CGFloat {
        let preferred: CGFloat = 640, floor: CGFloat = 560, margin: CGFloat = 150
        guard let visibleScreen else { return preferred }
        return max(floor, min(preferred, visibleScreen - margin))
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: Binding(
                get: { current },
                set: { new in
                    guard new != current else { return }
                    recording.stop()
                    direction.wrappedValue = new.rawValue > current.rawValue ? 1 : -1
                    withAnimation(reduceMotionFree(PK.Motion.easeOut(0.32))) { selection.wrappedValue = new }
                }
            ))
            .frame(width: 216)
            .padding(8)

            ZStack {
                pane
                    .id(current)
                    .transition(.asymmetric(
                        insertion: .offset(x: CGFloat(direction.wrappedValue) * 14).combined(with: .opacity),
                        removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 840, height: height)
        .background(SettingsWindowReader())
        .modifier(WindowGlass(enabled: windowBackground))
        .onDisappear { recording.stop() }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func reduceMotionFree(_ animation: Animation) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : animation
    }

    @ViewBuilder private var pane: some View {
        switch current {
        case .general: GeneralPane(store: store, updates: updates)
        case .shortcuts: ShortcutsPane(store: store, recording: recording)
        case .apps: AppsPane(store: store, sources: sources)
        case .sites: SitesPane(store: store, sources: sources)
        case .words: WordsPane(store: store, layouts: sources.layouts)
        case .privacy: PrivacyPane(store: store, usage: usage, layoutNames: sources.layouts.map { FalseSwitchReport.layoutName($0.id) })
        }
    }
}

/// Window Glass behind everything on macOS 15+; the system background on 14.
private struct WindowGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *), enabled {
            content.containerBackground(.regularMaterial, for: .window)
        } else {
            content
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Namespace private var strip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarItem(section: section, selected: selection == section, namespace: strip) {
                    selection = section
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // A material, not Liquid Glass: the selection strip inside is the glass,
            // and glass does not sit on glass.
            RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous).fill(Color.pkWash))
        }
        .overlay(RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: section.tile, startPoint: .top, endPoint: .bottom))
                    )
                    .accessibilityHidden(true)
                section.title
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Color.pkInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                if selected {
                    Color.clear
                        .glassStrip(in: RoundedRectangle(cornerRadius: 9, style: .continuous), glow: false)
                        .matchedGeometryEffect(id: "strip", in: namespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Bringing Settings to the front

/// A menu bar app has no Dock icon, so `SettingsLink` opens the window behind
/// the frontmost app. Activate the app, then raise the window.
@MainActor
enum SettingsFront {
    private(set) static weak var window: NSWindow?

    static func register(_ window: NSWindow?) {
        guard let window, window !== Self.window else { return }
        Self.window = window
        raise()
    }

    static func raise() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // The link opens the window a moment after the click; once more when it exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Hands the hosting window to `SettingsFront`.
private struct SettingsWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { SettingsFront.register(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { SettingsFront.register(view.window) }
    }
}
