// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// The sidebar sections of the Settings window.
enum SettingsSection: Int, CaseIterable, Identifiable {
    case general, shortcuts
    #if PEREKEY_VOICE
    case voice
    case voiceModes
    #endif
    case apps, sites, words, privacy

    var id: Int { rawValue }

    var title: Text {
        switch self {
        case .general: Text("General")
        case .shortcuts: Text("Shortcuts")
        #if PEREKEY_VOICE
        case .voice: voiceText("Voice")
        case .voiceModes: voiceText("Voice modes")
        #endif
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
        #if PEREKEY_VOICE
        case .voice: "mic.fill"
        case .voiceModes: "text.badge.plus"
        #endif
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
        #if PEREKEY_VOICE
        case .voice: [Color(red: 1, green: 0.45, blue: 0.52), Color(red: 0.88, green: 0.27, blue: 0.42)]
        case .voiceModes: [Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.37, green: 0.36, blue: 0.90)]
        #endif
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
    let languages: LanguageStatsStore?
    let usage: UsageRecorder?
    #if PEREKEY_VOICE
    /// The speech models and the voice settings; the Voice tab is empty without it.
    var voiceController: VoiceModelsController?
    /// The dictation modes; the Voice modes tab is empty without them.
    var voiceModes: VoiceModesStore?
    var voiceTextController: VoiceTextController?
    /// The recordings: the Records group of the Voice tab.
    var voiceTranscripts: TranscriptsController?
    #endif
    /// A view of the first pane to scroll to when it opens; gone once the person picks another pane.
    private let scrollTarget: State<String?>
    private let selection: State<SettingsSection>
    private let direction = State(initialValue: 1)

    init(store: SettingsStore, recording: ShortcutRecording, sources: InputSources, updates: Updates,
         usage: UsageRecorder? = nil, languages: LanguageStatsStore? = nil, initial: SettingsSection = .general,
         scrollTarget: String? = nil) {
        self.scrollTarget = State(initialValue: scrollTarget)
        self.usage = usage
        self.languages = languages
        self.updates = updates
        self.store = store
        self.recording = recording
        self.sources = sources
        selection = State(initialValue: initial)
    }

    private var current: SettingsSection { selection.wrappedValue }

    /// 640pt, but never taller than the visible screen minus 150pt, and never under 560pt.
    private var height: CGFloat {
        Self.windowHeight(visibleScreen: SettingsWindow.screen?.visibleFrame.height)
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
                    scrollTarget.wrappedValue = nil
                    direction.wrappedValue = new.rawValue > current.rawValue ? 1 : -1
                    withAnimation(reduceMotionFree(PK.Motion.easeOut(0.32))) { selection.wrappedValue = new }
                }
            ))
            .frame(width: 216)
            .padding(8)

            ZStack {
                pane
                    .environment(\.pkScrollTarget, scrollTarget.wrappedValue)
                    .id(current)
                    .transition(.asymmetric(
                        insertion: .offset(x: CGFloat(direction.wrappedValue) * 14).combined(with: .opacity),
                        removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 840, height: height)
        .onDisappear { recording.stop() }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func reduceMotionFree(_ animation: Animation) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : animation
    }

    @ViewBuilder private var pane: some View {
        switch current {
        case .general: GeneralPane(store: store, updates: updates, layouts: sources.layouts, sources: sources)
        case .shortcuts: ShortcutsPane(store: store, recording: recording, languages: LanguagePairs(layouts: sources.layouts).languages)
        #if PEREKEY_VOICE
        case .voice:
            if let voiceController {
                VoicePane(controller: voiceController, textController: voiceTextController, transcripts: voiceTranscripts,
                          store: store, recording: recording)
            }
        case .voiceModes:
            if let voiceModes, let voiceController { ModesPane(store: voiceModes, models: voiceController) }
        #endif
        #if PEREKEY_VOICE
        case .apps: AppsPane(store: store, sources: sources, languages: languages, voice: voiceController?.settings)
        #else
        case .apps: AppsPane(store: store, sources: sources, languages: languages)
        #endif
        case .sites: SitesPane(store: store, sources: sources)
        case .words: WordsPane(store: store, layouts: sources.layouts)
        case .privacy: PrivacyPane(store: store, usage: usage, languages: languages, layoutNames: sources.layouts.map { FalseSwitchReport.layoutName($0.id) })
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

// MARK: - The Settings window

/// Owns the Settings window. A plain `NSWindow`, like onboarding: since macOS 14
/// `showSettingsWindow:` only logs "Please use SettingsLink" and opens nothing,
/// and `openSettings` needs a SwiftUI view inside a scene, which the AppKit menu
/// panel is not. The window is kept after closing, so it reopens where it was.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    /// The screen the window sizes itself to.
    static var screen: NSScreen? { current?.screen ?? NSScreen.main }
    private static weak var current: NSWindow?

    private let recording: ShortcutRecording
    private let content: @MainActor (SettingsSection, String?) -> SettingsView
    private var window: NSWindow?

    init(recording: ShortcutRecording, content: @escaping @MainActor (SettingsSection, String?) -> SettingsView) {
        self.recording = recording
        self.content = content
    }

    /// A menu bar app has no Dock icon: activate first, or the window opens
    /// behind the frontmost app.
    func show() {
        let window = window ?? make()
        SystemInputMenu.shared.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens Settings at `section`, scrolled to the view with `scrollTarget`. A
    /// window that is open is rebuilt, so that it opens there.
    func show(section: SettingsSection, scrollTarget: String? = nil) {
        if let window {
            self.window = nil
            window.delegate = nil
            window.close()
        }
        let window = make(section: section, scrollTarget: scrollTarget)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make(section: SettingsSection = .general, scrollTarget: String? = nil) -> NSWindow {
        let host = NSHostingView(rootView: content(section, scrollTarget))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = String(localized: "Perekey Settings")
        // Window Glass on macOS 15+, the system background on 14. In AppKit:
        // `containerBackground(_:for: .window)` only reaches SwiftUI's own windows.
        if #available(macOS 15, *) {
            let glass = NSVisualEffectView()
            glass.material = .underWindowBackground
            glass.blendingMode = .behindWindow
            glass.state = .followsWindowActiveState
            host.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                host.topAnchor.constraint(equalTo: glass.topAnchor),
                host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            window.contentView = glass
        } else {
            window.contentView = host
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        Self.current = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        recording.stop()
    }
}
