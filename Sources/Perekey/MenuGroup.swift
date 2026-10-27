// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput
import SwiftUI

/// What the menu preview shows instead of the user's life: a pause that never
/// comes, a fixed app, and five corrections so the number of rows has something to cut.
@MainActor
@Observable
final class MenuPreviewModel {
    /// Made on the first use: the model itself is cheap, `State` makes one on every redraw of the pane.
    @MainActor struct World {
        let pause = PauseState(frozen: PauseSet(), now: Date())
        let appModes: AppModeController
        let recents = RecentCorrections(MenuPreviewModel.sampleLog())
        let nav = MenuNav()

        init(sources: InputSources, store: SettingsStore) {
            appModes = AppModeController(sources: sources, store: store, pause: pause, live: false)
            appModes.freeze(frontmost: FrontApp(bundleID: "com.apple.Notes", name: "Notes", isGame: false))
        }
    }

    @ObservationIgnored let presentation = MenuPresentation()
    @ObservationIgnored private var made: World?
    /// The menu is taller than the room: it scrolls.
    var overflows = false
    /// The menu's natural height, for the frame of the scaled picture.
    var height = CGFloat(0)

    func world(sources: InputSources, store: SettingsStore) -> World {
        if let made { return made }
        let new = World(sources: sources, store: store)
        made = new
        return new
    }

    private static func sampleLog() -> CorrectionLog {
        var log = CorrectionLog()
        let rows: [(String, String, Correction.Kind)] = [
            ("ghbdtn", "привет", .layout), ("еще", "ещё", .yo), ("чтото", "что-то", .hyphen),
            ("мвд", "МВД", .abbreviation), ("прривет", "привет", .typo),
        ]
        for (index, row) in rows.enumerated() {
            log.record(Correction(seq: UInt32(index + 1), original: row.0, replacement: row.1, source: "en", target: "ru",
                                  kind: row.2), at: Date())
        }
        return log
    }
}

/// Settings → General → «Menu»: which blocks of the menu show, and a small live
/// copy of the menu that follows each switch and says whether it fits the screen.
struct MenuGroup: View {
    let store: SettingsStore
    /// The preview needs the layouts; `nil` leaves it out.
    var sources: InputSources?
    var updates: Updates?
    var usage: UsageRecorder?
    var launch: LaunchAtLogin?
    var voiceIsOn = false
    /// The voice parts of the menu (the preview draws them but nothing runs).
    var previewActions = MenuActions()
    /// The height the preview may take; `nil`: the room of the window's screen.
    var budget: CGFloat?

    private let modelState = State(initialValue: MenuPreviewModel())
    private let widthState = State(initialValue: CGFloat(0))
    @Environment(\.pkLiquidGlass) private var liquid

    private static let scale: CGFloat = 0.7
    /// The pane is wide enough for the list and the preview side by side from here.
    private static let sideBySide: CGFloat = 540

    private var model: MenuPreviewModel { modelState.wrappedValue }
    private var width: CGFloat { widthState.wrappedValue }

    private var layout: MenuLayout { store.settings.menu }

    var body: some View {
        let wide = width >= Self.sideBySide
        Group {
            if wide {
                HStack(alignment: .top, spacing: 16) {
                    list
                    preview
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widthState.wrappedValue = $0 }
    }

    // MARK: List

    private var list: some View {
        PKGroup(header: Text("Menu"), anchor: "general.menu") {
            blockRow(Text("Automatic switching and mode"), anchor: "general.menu-mode", .modeCard)
            PKDivider()
            blockRow(Text("Recent corrections"), anchor: "general.menu-corrections", .recentCorrections)
            #if PEREKEY_VOICE
            if voiceIsOn {
                PKDivider()
                blockRow(voiceText("Recent dictations"), anchor: "general.menu-dictations", .recentDictations)
            }
            #endif
            PKDivider()
            blockRow(Text("Pause for 1 hour"), anchor: "general.menu-pause", .pause)
            if launch != nil {
                PKDivider()
                blockRow(Text("Launch at login in the menu"), anchor: "general.menu-launch", .launchAtLogin)
            }
            #if PEREKEY_VOICE
            if voiceIsOn {
                PKDivider()
                blockRow(voiceText("Voice mode"), anchor: "general.menu-voice-mode", .voiceMode)
            }
            #endif
            PKDivider()
            blockRow(Text("Layouts as a list"), detail: Text("Instead of opening them from the header."),
                     anchor: "general.menu-layouts", .layoutsList)
            #if PEREKEY_VOICE
            if voiceIsOn {
                PKDivider()
                blockRow(voiceText("Transcripts"), anchor: "general.menu-transcripts", .transcripts)
                PKDivider()
                blockRow(voiceText("Transcribe File"), anchor: "general.menu-transcribe", .transcribeFile)
                PKDivider()
                blockRow(voiceText("Record a Call"), anchor: "general.menu-call", .callRecording)
            }
            #endif
            PKDivider()
            blockRow(Text("Check for Updates"), anchor: "general.menu-updates", .updates)
            PKDivider()
            blockRow(Text("How to Use Perekey"), anchor: "general.menu-how-to", .howTo)
            PKDivider()
            blockRow(Text("About Perekey"), anchor: "general.menu-about", .about)
            if usage != nil {
                PKDivider()
                blockRow(Text("Count for today"), detail: Text("Only while “Count corrections” is on in Privacy."),
                         anchor: "general.menu-statistics", .statistics)
            }
            PKDivider()
            PKNote(Text("Right-click a block in the menu to hide it. The layout, Settings and Quit always stay."))
            PKDivider()
            HStack {
                Spacer(minLength: 0)
                Button("Reset to Default") { store.update { $0.menu.reset() } }
                    .buttonStyle(.pkSecondary)
                    .disabled(layout.isDefault)
            }
            .padding(.horizontal, PK.Space.lg)
            .padding(.vertical, 11)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    /// A switch, or for a list the number of rows (0 hides it).
    private func blockRow(_ title: Text, detail: Text? = nil, anchor: String, _ block: MenuBlock) -> some View {
        PKRow(title, detail: detail, anchor: anchor) {
            if block.hasRows {
                PKSegmented(items: MenuLayout.rowChoices.map { .init(value: $0, label: Text(verbatim: "\($0)")) },
                            selection: Binding(get: { layout.rows(of: block) },
                                               set: { rows in store.update { $0.menu.setRows(rows, of: block) } }),
                            mini: true)
                    .accessibilityLabel(title)
            } else {
                Toggle(isOn: Binding(get: { layout.shows(block) },
                                     set: { on in store.update { $0.menu.set(block, shown: on) } })) { title }
                    .labelsHidden()
                    .toggleStyle(.pkSwitch)
            }
        }
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if let sources {
            VStack(alignment: .leading, spacing: 8) {
                picture(sources)
                fitLabel
            }
            .frame(width: 318 * Self.scale, alignment: .topLeading)
            .accessibilityElement(children: .contain)
        }
    }

    private func picture(_ sources: InputSources) -> some View {
        let shape = RoundedRectangle(cornerRadius: PK.Radius.menu, style: .continuous)
        let world = model.world(sources: sources, store: store)
        var content = MenuContent(sources: sources, store: store, pause: world.pause, appModes: world.appModes,
                                  recents: world.recents, usage: usage, launch: launch, nav: world.nav,
                                  actions: previewActions, updates: updates, presentation: model.presentation)
        content.editable = false
        content.onOverflow = { [model] in if model.overflows != $0 { model.overflows = $0 } }
        return content
            .modifier(MenuSurface(shape: shape, liquid: liquid))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.height = $0 }
            .scaleEffect(Self.scale, anchor: .topLeading)
            .frame(width: 318 * Self.scale, height: model.height * Self.scale, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { model.presentation.budget = room }
            .onChange(of: room) { _, new in model.presentation.budget = new }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
                model.presentation.budget = room
            }
    }

    /// The menu's room on the screen of the Settings window, as `MenuPanelController` counts it.
    private var room: CGFloat {
        if let budget { return budget }
        guard let visible = (SettingsWindow.screen ?? NSScreen.main)?.visibleFrame else { return .infinity }
        return CGFloat(MenuRoom.budget(itemBottom: visible.maxY, visibleBottom: visible.minY))
    }

    private var fitLabel: some View {
        let fits = !model.overflows
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: fits ? "checkmark.circle" : "arrow.up.and.down.text.horizontal")
                .frame(width: 14)
            if fits {
                Text("Fits on this screen")
            } else {
                Text("Does not fit on this screen: it will scroll")
            }
        }
        .font(PK.Font.caption)
        .foregroundStyle(Color.pkInk2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
