// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput
import ServiceManagement
import SwiftUI

/// What the menu asks its owner to do. Every action closes the menu first.
struct MenuActions {
    var openSettings: () -> Void = {}
    /// Opens Settings → General at the «Menu» group.
    var customizeMenu: () -> Void = {}
    var showOnboarding: () -> Void = {}
    /// Opens the access step of onboarding.
    var openAccess: () -> Void = {}
    var showAbout: () -> Void = {}
    var quit: () -> Void = {}
    /// Opens the report form with this word and the classifier's decision
    /// (names and numbers) filled in.
    var report: (String, String) -> Void = { _, _ in }
    var close: () -> Void = {}
    #if PEREKEY_VOICE
    /// The voice mode switch; nil hides it.
    var voiceModes: VoiceModeMenu?
    /// The recent dictations; nil hides the section.
    var dictation: DictationMenu?
    /// «Записать созвон»; nil hides it.
    var callRecording: CallRecordingController?
    /// The «Расшифровки» window; nil hides the row.
    var transcripts: TranscriptsMenu?
    /// «Конспект» and «Протокол встречи» that go on, each a row with «Остановить».
    var summaries: TranscriptSummaries?
    /// «Расшифровать файл…»; nil, or false from it, hides the row.
    var transcribeFile: (() -> Void)?
    var canTranscribeFiles: () -> Bool = { false }
    #endif
}

// MARK: - Keyboard navigation

/// The rows the keyboard can reach, in screen order, and the one that is lit.
/// Rows register their id through a preference (order) and `onAppear` (action).
@MainActor
@Observable
final class MenuNav {
    struct Action {
        var run: @MainActor () -> Void
        var step: (@MainActor (Int) -> Void)?
    }

    /// The keyboard moved to this row: the scroll area brings it into view.
    /// `token` makes a second move to the same row a new request.
    struct ScrollRequest: Equatable {
        let id: String
        let token: Int
    }

    /// The rows above the scroll area and the rows in it: a preference does not
    /// leave a `ScrollView`, so each part reports its own.
    var topOrder: [String] = []
    var bodyOrder: [String] = []
    var order: [String] { topOrder + bodyOrder }
    var highlighted: String?
    var scrollRequest: ScrollRequest?
    @ObservationIgnored var actions: [String: Action] = [:]

    func move(_ delta: Int) {
        guard !order.isEmpty else { return }
        let next: Int
        if let current = highlighted.flatMap({ order.firstIndex(of: $0) }) {
            next = (current + delta + order.count) % order.count
        } else {
            next = delta > 0 ? 0 : order.count - 1
        }
        highlighted = order[next]
        scrollRequest = ScrollRequest(id: order[next], token: (scrollRequest?.token ?? 0) + 1)
    }

    func activate() {
        guard let highlighted else { return }
        actions[highlighted]?.run()
    }

    func step(_ delta: Int) {
        guard let highlighted else { return }
        actions[highlighted]?.step?(delta)
    }

    func hover(_ id: String, _ inside: Bool) {
        if inside {
            highlighted = id
        } else if highlighted == id {
            highlighted = nil
        }
    }
}

private struct MenuOrderKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

private struct MenuItemModifier: ViewModifier {
    let id: String
    let nav: MenuNav
    let active: Bool
    let step: (@MainActor (Int) -> Void)?
    let run: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .id(id)
            .preference(key: MenuOrderKey.self, value: active ? [id] : [])
            .onHover { if active { nav.hover(id, $0) } }
            .onAppear { nav.actions[id] = MenuNav.Action(run: run, step: step) }
            .onDisappear { nav.actions[id] = nil }
    }
}

extension View {
    /// `active: false` keeps the row out of the keyboard's reach (a folded list).
    func menuItem(_ id: String, nav: MenuNav, active: Bool = true, step: (@MainActor (Int) -> Void)? = nil,
                  run: @escaping @MainActor () -> Void) -> some View {
        modifier(MenuItemModifier(id: id, nav: nav, active: active, step: step, run: run))
    }
}

/// The ring a keyboard-lit control wears.
private struct LitRing: ViewModifier {
    let lit: Bool
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.pkIndigo, lineWidth: 1.5)
                .opacity(lit ? 1 : 0)
        )
    }
}

/// What a right click on a block of the menu offers.
struct BlockMenu {
    let hide: () -> Void
    let customize: () -> Void
}

private struct BlockContextMenu: ViewModifier {
    let menu: BlockMenu?

    @ViewBuilder func body(content: Content) -> some View {
        if let menu {
            content.contextMenu {
                Button("Hide from Menu", action: menu.hide)
                Divider()
                Button("Customize Menu…", action: menu.customize)
            }
        } else {
            content
        }
    }
}

extension View {
    /// A right click (or Control-click) offers «Hide from Menu»; `nil` leaves the row without a menu.
    func blockMenu(_ menu: BlockMenu?) -> some View {
        modifier(BlockContextMenu(menu: menu))
    }
}

// MARK: - Menu

/// The menu panel's content: header, held-state card, mode, recent corrections,
/// switches, layouts and commands. Structure follows `pmenu` in `design/mockup.html`.
struct MenuContent: View {
    let sources: InputSources
    let store: SettingsStore
    let pause: PauseState
    let appModes: AppModeController
    let recents: RecentCorrections
    /// `nil` hides the statistics line (snapshots, tests).
    var usage: UsageRecorder?
    /// `nil` hides «Launch at login» (snapshots, tests).
    var launch: LaunchAtLogin?
    var nav = MenuNav()
    var actions = MenuActions()
    /// `nil` hides "Check for Updates…" (snapshots).
    var updates: Updates?
    /// The row whose «Why?» starts open (snapshots).
    var explainedEntry: Int?
    /// Whether Perekey has access; read in `body`, so the row follows it.
    var hasAccess: @MainActor () -> Bool = { true }
    /// Carries the height the menu may take.
    var presentation = MenuPresentation()
    /// The layouts list starts open (snapshots).
    var layoutsOpenAtStart = false
    /// Told whether what is under the header is taller than the room, so it scrolls.
    var onOverflow: ((Bool) -> Void)?
    /// A right click offers «Hide from Menu»; false in the preview of Settings.
    var editable = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last reason, so the card keeps its text while it folds away.
    private let lastReason = State<PauseReason?>(initialValue: nil)
    /// The list of layouts under the header is open.
    private let layoutsOpen = State(initialValue: false)
    /// The height of the part that stays in place, for the scroll area's share.
    private let topHeight = State(initialValue: CGFloat(0))
    /// The scroll area never gets less than this, so Quit stays within reach.
    private static var minScroll: CGFloat { 120 }

    var body: some View {
        let heldReason = pause.current ?? lastReason.wrappedValue
        let open = layoutsOpen.wrappedValue && canExpandLayouts
        VStack(alignment: .leading, spacing: 0) {
            // Stays in place; what is under it scrolls when the screen is too low.
            VStack(alignment: .leading, spacing: 0) {
                if !hasAccess() {
                    accessRow
                }
                header
            }
            .background(GeometryReader { Color.clear.preference(key: TopHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(TopHeightKey.self) { topHeight.wrappedValue = $0 }
            .onPreferenceChange(MenuOrderKey.self) { nav.topOrder = $0 }
            MenuScroll(nav: nav, limit: max(presentation.budget - topHeight.wrappedValue, Self.minScroll),
                       onOverflow: onOverflow) {
                // The header's list is not built while the block below shows the same list.
                if !hasList {
                    Reveal(open: open) {
                        LayoutsList(sources: sources, nav: nav, active: open, onSelected: actions.close)
                            .padding(.bottom, 8)
                            .accessibilityHidden(!open)
                            .allowsHitTesting(open)
                    }
                }
                Reveal(open: pause.current != nil) {
                    if let reason = heldReason {
                        PauseCard(reason: reason, now: pause.now, nav: nav, onAction: { action(for: reason) })
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }
                }
                if shows(.modeCard) {
                    modeCard
                        .padding(.horizontal, 12)
                        .blockMenu(menu(.modeCard))
                }
                if rows(.recentCorrections) > 0 {
                    recentSection
                        .blockMenu(menu(.recentCorrections))
                }
                #if PEREKEY_VOICE
                if let dictation = actions.dictation, showsDictations(dictation) {
                    DictationMenuSection(menu: dictation, nav: nav, rows: rows(.recentDictations), close: actions.close)
                        .blockMenu(rows(.recentDictations) > 0 ? menu(.recentDictations) : nil)
                }
                #endif
                if hasTop && hasSwitches { PKDivider(leading: 12, trailing: 12).padding(.top, 10) }
                if hasSwitches {
                    VStack(alignment: .leading, spacing: 2) {
                        if shows(.pause) {
                            switchRow(
                                id: "pause", title: "Pause for 1 hour", subtitle: nil,
                                isOn: Binding(
                                    get: { pause.isTimedPauseActive },
                                    set: { $0 ? pause.pauseForOneHour() : pause.resumeTimed() }
                                )
                            )
                            .blockMenu(menu(.pause))
                        }
                        if let launch, shows(.launchAtLogin) {
                            LaunchAtLoginRow(launch: launch, nav: nav)
                                .blockMenu(menu(.launchAtLogin))
                        }
                        #if PEREKEY_VOICE
                        if let voiceModes = actions.voiceModes, shows(.voiceMode), voiceModes.isOn() {
                            VoiceModeMenuRow(menu: voiceModes, appModes: appModes, lit: nav.highlighted == "voice-mode")
                                .menuItem("voice-mode", nav: nav, step: { voiceModes.step($0) }, run: { voiceModes.step(1) })
                                .blockMenu(menu(.voiceMode))
                        }
                        #endif
                    }
                    .padding(.vertical, 6)
                }
                if hasList {
                    if hasTop || hasSwitches { PKDivider(leading: 12, trailing: 12).padding(.top, hasSwitches ? 0 : 10) }
                    LayoutsList(sources: sources, nav: nav, onSelected: actions.close)
                        .padding(.vertical, 6)
                        .blockMenu(menu(.layoutsList))
                }
                if hasTop || hasSwitches || hasList { PKDivider(leading: 12, trailing: 12) }
                commands
                    .padding(.vertical, 6)
                if let usage, store.settings.statistics, shows(.statistics) {
                    usageLine(usage)
                        .blockMenu(menu(.statistics))
                }
            }
        }
        .frame(width: 318)
        .onAppear {
            lastReason.wrappedValue = pause.current
            if layoutsOpenAtStart {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { layoutsOpen.wrappedValue = true }
            }
            #if PEREKEY_VOICE
            // Expired dictations go when the menu opens, at most once a day.
            // Only the live menu cleans: the preview in Settings has no side effects.
            if editable {
                actions.dictation?.history.purgeIfDue()
                actions.callRecording?.purgeIfDue()
            }
            #endif
        }
        .onChange(of: pause.current) { _, new in
            if let new { lastReason.wrappedValue = new }
        }
        .environment(nav)
    }

    // MARK: Blocks

    private func shows(_ block: MenuBlock) -> Bool { store.settings.menu.shows(block) }

    private func rows(_ block: MenuBlock) -> Int { store.settings.menu.rows(of: block) }

    /// A right click on a block: hide it, or open the settings of the menu.
    private func menu(_ block: MenuBlock) -> BlockMenu? {
        guard editable else { return nil }
        return BlockMenu(hide: {
            store.update { $0.menu.set(block, shown: false) }
            // The lit row may be in the block that goes: the keyboard would be left on nothing.
            if let lit = nav.highlighted, Self.owns(block, row: lit) { nav.highlighted = nil }
        }, customize: actions.customizeMenu)
    }

    /// Whether a row id belongs to a block of the menu.
    static func owns(_ block: MenuBlock, row id: String) -> Bool {
        switch block {
        case .modeCard: id == "mode"
        case .recentCorrections: id.hasPrefix("fix-")
        case .recentDictations: id.hasPrefix("dictation-")
        case .pause: id == "pause"
        case .voiceMode: id == "voice-mode"
        case .transcripts: id == "transcripts" || id.hasPrefix("summary-")
        case .transcribeFile: id == "transcribe-file"
        case .callRecording: id == "call"
        case .updates: id == "updates"
        case .about: id == "about"
        case .statistics: false
        case .launchAtLogin: id == "launch"
        case .howTo: id == "onboarding"
        case .layoutsList: id.hasPrefix("layout-")
        }
    }

    /// The card, the lists and the dictations: what stands above the switches.
    private var hasTop: Bool {
        var top = shows(.modeCard) || rows(.recentCorrections) > 0
        #if PEREKEY_VOICE
        if let dictation = actions.dictation, showsDictations(dictation) { top = true }
        #endif
        return top
    }

    private var hasSwitches: Bool {
        var any = shows(.pause) || (launch != nil && shows(.launchAtLogin))
        #if PEREKEY_VOICE
        if let voiceModes = actions.voiceModes, shows(.voiceMode), voiceModes.isOn() { any = true }
        #endif
        return any
    }

    /// The layouts as a list in the body, with no chevron in the header.
    private var hasList: Bool { shows(.layoutsList) && !sources.layouts.isEmpty }

    #if PEREKEY_VOICE
    /// An unsaved dictation shows while there is one, whatever the number of rows.
    private func showsDictations(_ dictation: DictationMenu) -> Bool {
        dictation.history.unsaved != nil || (rows(.recentDictations) > 0 && !dictation.history.entries.isEmpty)
    }
    #endif

    // MARK: Header

    /// More than one layout, and no list of them in the body: the header opens the list.
    private var canExpandLayouts: Bool { sources.layouts.count > 1 && !shows(.layoutsList) }

    private var layoutName: String { sources.currentLayout.map(sources.name(of:)) ?? String(localized: "No layout") }

    private var header: some View {
        let open = layoutsOpen.wrappedValue
        return Group {
            if canExpandLayouts {
                Button { layoutsOpen.wrappedValue.toggle() } label: {
                    headerStrip(chevron: true, open: open)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Layouts"))
                .accessibilityValue(Text(verbatim: open ? String(localized: "\(layoutName), expanded")
                                         : String(localized: "\(layoutName), collapsed")))
                .menuItem("header", nav: nav) { layoutsOpen.wrappedValue.toggle() }
            } else {
                headerStrip(chevron: false, open: false)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func headerStrip(chevron: Bool, open: Bool) -> some View {
        HStack(spacing: 10) {
            CapsuleView(
                model: CapsuleModel(code: sources.currentLayout.map(sources.indicator(of:)) ?? "⌨", struck: !store.settings.autoswitch),
                dark: colorScheme == .dark, height: 30, fontSize: 17, animated: true, flash: recents.flashes
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: layoutName)
                    .font(PK.Font.headline)
                    .foregroundStyle(Color.pkInk)
                Text(hintLine)
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.pkInk2)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.easeOut(0.45), value: open)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous), glow: false)
        .modifier(LitRing(lit: nav.highlighted == "header", radius: PK.Radius.row))
    }

    /// The shortcuts as the user set them: «⇧ — switch layout · ⌥ — retype word».
    private var hintLine: String {
        var parts: [String] = []
        if let trigger = store.settings.trigger(for: .switchLayout) {
            parts.append(String(localized: "\(keys(of: trigger)) — switch"))
        }
        if let trigger = store.settings.trigger(for: .convertLastWord) {
            parts.append(String(localized: "\(keys(of: trigger)) — retype"))
        }
        if parts.isEmpty {
            return store.settings.autoswitch ? String(localized: "Automatic switching is on") : String(localized: "Automatic switching is off")
        }
        return parts.joined(separator: " · ")
    }

    private func keys(of trigger: Trigger) -> String {
        TriggerText.keycaps(of: trigger).joined(separator: " ")
    }

    // MARK: Switch and mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            let toggle = store.settings.trigger(for: .toggleAutoswitch)
            switchRow(
                id: "autoswitch", title: "Automatic switching",
                subtitle: toggle.map { String(localized: "Turn on or off: \(keys(of: $0))") },
                isOn: Binding(
                    get: { store.settings.autoswitch },
                    set: { value in store.update { $0.autoswitch = value } }
                ),
                inset: false
            )
            if let app = appModes.frontmost {
                modeRow(app)
            }
        }
        .padding(10)
        .pkCard()
    }

    private func modeRow(_ app: FrontApp) -> some View {
        let lit = nav.highlighted == "mode"
        let modes = AppMode.allCases
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mode").font(PK.Font.body).foregroundStyle(Color.pkInk)
                Text(verbatim: app.name).font(PK.Font.caption).foregroundStyle(Color.pkInk2).lineLimit(1)
            }
            Spacer(minLength: 4)
            PKSegmented(
                items: modes.map { PKSegmented<AppMode>.Item(value: $0, label: Text($0.title)) },
                selection: Binding(
                    get: { appModes.mode },
                    set: { store.setMode($0, for: app.bundleID) }
                ),
                mini: true
            )
        }
        .padding(2)
        .modifier(LitRing(lit: lit))
        .menuItem("mode", nav: nav, step: { delta in
            guard let index = modes.firstIndex(of: appModes.mode) else { return }
            store.setMode(modes[max(0, min(modes.count - 1, index + delta))], for: app.bundleID)
        }, run: {
            guard let index = modes.firstIndex(of: appModes.mode) else { return }
            store.setMode(modes[(index + 1) % modes.count], for: app.bundleID)
        })
    }

    private func switchRow(id: String, title: LocalizedStringKey, subtitle: String?, isOn: Binding<Bool>,
                           inset: Bool = true) -> some View {
        SwitchLine(title: title, subtitle: subtitle, isOn: isOn)
            .padding(.horizontal, inset ? 12 : 0)
            .padding(.vertical, inset ? 3 : 0)
            .modifier(LitRing(lit: nav.highlighted == id))
            .menuItem(id, nav: nav) { isOn.wrappedValue.toggle() }
    }

    // MARK: Recent corrections

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent corrections").font(PK.Font.captionStrong).foregroundStyle(Color.pkInk2)
                Spacer()
                Text("memory only").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            }
            .padding(.horizontal, 4)
            if recents.log.isEmpty {
                Text("Nothing yet. Corrections appear here as you type.")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    let entries = Array(recents.log.entries.prefix(rows(.recentCorrections)))
                    let latest = entries.first { !$0.undone }?.id
                    ForEach(entries) { entry in
                        CorrectionRow(entry: entry, isLatest: entry.id == latest, store: store, nav: nav,
                                      onReport: { word, reason in actions.report(word, reason) },
                                      explained: entry.id == explainedEntry)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.easeOut(0.32), value: Array(recents.log.entries.prefix(rows(.recentCorrections))))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: Statistics

    /// «Today: 23 corrections · 1 undone», only while the user counts corrections.
    private func usageLine(_ usage: UsageRecorder) -> some View {
        _ = usage.revision
        let today = usage.stats.day(at: Date())
        let total = today.correctionTotal
        var text = total == 0 ? String(localized: "Today: no corrections") : String(localized: "Today: \(total) corrections")
        if today.undone > 0 { text += " · " + String(localized: "\(today.undone) undone") }
        return Text(verbatim: text)
            .font(PK.Font.caption)
            .foregroundStyle(Color.pkInk2)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(verbatim: text))
    }

    // MARK: Commands

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if PEREKEY_VOICE
            if let transcripts = actions.transcripts, shows(.transcripts), transcripts.isOn() {
                MenuCommandRow(id: "transcripts", title: "", label: voiceText("Transcripts…"), shortcut: nil, nav: nav,
                               run: { actions.close(); transcripts.open() })
                    .blockMenu(menu(.transcripts))
            }
            if let summaries = actions.summaries {
                // A run goes on with the window closed, and never unseen: one line each, a click stops it.
                ForEach(summaries.running.sorted { $0.key.uuidString < $1.key.uuidString }, id: \.key) { id, running in
                    MenuCommandRow(id: "summary-\(id.uuidString)", title: "",
                                   label: Text(verbatim: "\(running.action.menuText(running.progress)) · \(voiceString("Stop"))"),
                                   shortcut: nil, nav: nav) { summaries.cancel(id) }
                        .accessibilityHint(voiceText("Stops it"))
                }
            }
            if let transcribeFile = actions.transcribeFile, shows(.transcribeFile), actions.canTranscribeFiles() {
                MenuCommandRow(id: "transcribe-file", title: "Transcribe File…", table: "Voice", nav: nav) {
                    guard editable else { return }
                    actions.close()
                    transcribeFile()
                }
                .blockMenu(menu(.transcribeFile))
            }
            // A call being recorded keeps its «Stop Recording» in the menu, hidden or not.
            if let call = actions.callRecording, call.isAvailable, call.isRecording || shows(.callRecording) {
                if call.isRecording {
                    MenuCommandRow(id: "call", title: "Stop Recording", table: "Voice", nav: nav) {
                        guard editable else { return }
                        actions.close()
                        call.menuAction()
                    }
                } else {
                    MenuCommandRow(id: "call", title: "Record a Call…", table: "Voice", nav: nav) {
                        guard editable else { return }
                        actions.close()
                        call.menuAction()
                    }
                    .blockMenu(menu(.callRecording))
                }
            }
            #endif
            MenuCommandRow(id: "settings", title: "Settings…", shortcut: "⌘,", nav: nav, run: actions.openSettings)
            if let updates {
                UpdatesMenuRow(updates: updates, nav: nav, checkShown: shows(.updates), blockMenu: menu(.updates),
                               close: actions.close)
            }
            if shows(.howTo) {
                MenuCommandRow(id: "onboarding", title: "How to Use Perekey", shortcut: nil, nav: nav, run: actions.showOnboarding)
                    .blockMenu(menu(.howTo))
            }
            if shows(.about) {
                MenuCommandRow(id: "about", title: "About Perekey", shortcut: nil, nav: nav, run: actions.showAbout)
                    .blockMenu(menu(.about))
            }
            MenuCommandRow(id: "quit", title: "Quit Perekey", shortcut: "⌘Q", nav: nav, run: actions.quit)
        }
    }

    /// The first row while Perekey has no access: the one thing that matters.
    private var accessRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuCommandRow(id: "access", title: "No access — grant access…", warn: true, nav: nav, run: actions.openAccess)
            PKDivider(leading: 12, trailing: 12).padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func action(for reason: PauseReason) {
        switch reason {
        case .timed: pause.resumeTimed()
        case .appOff: pause.onTurnOnHere?()
        case .secureInput, .passwordField: break
        }
    }
}

// MARK: - Scroll

private struct TopHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What is under the menu's header. It is as tall as its content up to `limit`
/// (the screen's room), then it scrolls: the keyboard brings the lit row into
/// view and the bottom fades while there is more below.
private struct MenuScroll<Content: View>: View {
    let nav: MenuNav
    let limit: CGFloat
    var onOverflow: ((Bool) -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let contentHeight = State(initialValue: CGFloat(0))
    /// Where the content's top stands in the viewport: 0 at rest, below 0 scrolled.
    private let contentTop = State(initialValue: CGFloat(0))
    private let viewport = State(initialValue: CGFloat(0))

    private static var top: String { "menu-top" }
    private static var space: String { "menu-scroll" }
    private static var fade: CGFloat { 28 }

    var body: some View {
        let more = contentHeight.wrappedValue > viewport.wrappedValue + 1
            && contentTop.wrappedValue + contentHeight.wrappedValue > viewport.wrappedValue + 1
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.top)
                    content
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight.wrappedValue = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: {
                    contentTop.wrappedValue = $0
                }
                .onPreferenceChange(MenuOrderKey.self) { nav.bodyOrder = $0 }
            }
            .coordinateSpace(name: Self.space)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(maxHeight: limit.isFinite ? max(limit, 0) : nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport.wrappedValue = $0 }
            .onChange(of: contentHeight.wrappedValue > viewport.wrappedValue + 1, initial: true) { _, overflows in
                onOverflow?(overflows)
            }
            .mask { fadeMask(more) }
            .onChange(of: nav.scrollRequest) { _, request in
                guard let request else { return }
                // The header is above the scroll area: its top is the nearest place.
                let above = request.id == "access" || request.id == "header"
                withAnimation(reduceMotion ? nil : PK.Motion.easeOut(0.2)) {
                    proxy.scrollTo(above ? Self.top : request.id, anchor: above ? .top : nil)
                }
            }
        }
    }

    private func fadeMask(_ more: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
            ZStack {
                Rectangle().opacity(more ? 0 : 1)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).opacity(more ? 1 : 0)
            }
            .frame(height: Self.fade)
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.easeOut(0.2), value: more)
    }
}

// MARK: - Reveal

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Opens from zero height to the content's height (grid-rows reveal, .45 s).
/// Under Reduce Motion it fades instead.
private struct Reveal<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: Content
    private let measured = State(initialValue: CGFloat(0))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = measured.wrappedValue
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            .onPreferenceChange(HeightKey.self) { measured.wrappedValue = $0 }
            .frame(height: reduceMotion ? nil : (open ? (height > 0 ? height : nil) : 0), alignment: .top)
            .clipped()
            .opacity(open ? 1 : 0)
            .frame(height: reduceMotion && !open ? 0 : nil, alignment: .top)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.easeOut(0.45), value: open)
    }
}

// MARK: - Rows

/// The card for the active pause reason, with its action when the user can end it here.
struct PauseCard: View {
    let reason: PauseReason
    let now: Date
    var nav: MenuNav?
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
                    actionButton(title)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .pkCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actionButton(_ title: String) -> some View {
        let button = Button(title, action: onAction).buttonStyle(.pkSmall)
        if let nav {
            button
                .modifier(LitRing(lit: nav.highlighted == "held-action", radius: 12))
                .menuItem("held-action", nav: nav, run: onAction)
        } else {
            button
        }
    }
}

/// A title on the left and its switch on the right.
struct SwitchLine: View {
    let title: LocalizedStringKey
    var subtitle: String?
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PK.Font.body).foregroundStyle(Color.pkInk)
                if let subtitle {
                    Text(subtitle).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                }
            }
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
    let nav: MenuNav

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
        .modifier(LitRing(lit: nav.highlighted == "launch"))
        .menuItem("launch", nav: nav) { if launch.isAvailable { launch.setEnabled(!launch.isOn) } }
    }
}

/// A command: Solid Indigo Fill with white text when hovered or lit by the keyboard.
struct MenuCommandRow: View {
    let id: String
    let title: LocalizedStringKey
    /// Text in place of `title`, for a string of another table.
    var label: Text?
    /// The strings table of the title: `Voice` for voice rows.
    var table: String?
    var shortcut: String?
    var checked = false
    var badge = false
    /// Amber with a triangle: something does not work.
    var warn = false
    var enabled = true
    /// False while the row is folded away: the keyboard skips it.
    var navigable = true
    let nav: MenuNav
    let run: () -> Void

    var body: some View {
        let hot = enabled && nav.highlighted == id
        Button(action: run) {
            HStack {
                if warn { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .bold)) }
                (label ?? Text(title, tableName: table)).font(PK.Font.body)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                if badge {
                    Circle().fill(hot ? Color.white : Color.pkIndigo).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                if let shortcut { Text(shortcut).font(PK.Font.body).opacity(hot ? 0.8 : 0.55) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .foregroundStyle(hot ? Color.white : (warn ? Color.pkWarn : Color.pkInk))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hot ? Color.pkIndigoFill : .clear))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .menuItem(id, nav: nav, active: navigable, run: { if enabled { run() } })
    }
}

/// "Check for Updates…", or the gentle reminder of a found update. Hidden when
/// a profile forbids updates; dimmed in a build that cannot update itself.
struct UpdatesMenuRow: View {
    let updates: Updates
    let nav: MenuNav
    /// False hides «Check for Updates…»; the row of a found update stays.
    var checkShown = true
    var blockMenu: BlockMenu?
    let close: () -> Void

    var body: some View {
        let policy = updates.policy
        if policy.state != .managedOff {
            if let version = updates.pendingVersion {
                MenuCommandRow(id: "updates", title: "Install Update \(version)…", shortcut: nil, badge: true,
                               enabled: policy.canCheckNow, nav: nav, run: run)
            } else if checkShown {
                MenuCommandRow(id: "updates", title: "Check for Updates…", shortcut: nil,
                               enabled: policy.canCheckNow, nav: nav, run: run)
                    .blockMenu(blockMenu)
            }
        }
    }

    private func run() {
        close()
        updates.checkNow()
    }
}

/// The enabled layouts with a checkmark on the selected one; a click selects.
/// The header of the menu opens it.
struct LayoutsList: View {
    let sources: InputSources
    let nav: MenuNav
    /// False while the list is folded: its rows are out of the keyboard's reach.
    var active = true
    let onSelected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.layouts, id: \.id) { layout in
                MenuCommandRow(id: "layout-\(layout.id.rawValue)", title: LocalizedStringKey(sources.name(of: layout.id)),
                               checked: sources.currentLayout == layout.id, navigable: active, nav: nav) {
                    sources.select(layout.id)
                    onSelected()
                }
            }
        }
    }
}

// MARK: - Recent corrections

/// One correction: kind icon, `from → to`, and its two actions. The newest one
/// that still stands is a glass strip; an undone one has its new word struck.
struct CorrectionRow: View {
    let entry: CorrectionLog.Entry
    let isLatest: Bool
    let store: SettingsStore
    let nav: MenuNav
    let onReport: (String, String) -> Void
    /// «Why?» is open: the reasons show under the row.
    private let explained: State<Bool>

    init(entry: CorrectionLog.Entry, isLatest: Bool, store: SettingsStore, nav: MenuNav,
         onReport: @escaping (String, String) -> Void, explained: Bool = false)
    {
        self.entry = entry
        self.isLatest = isLatest
        self.store = store
        self.nav = nav
        self.onReport = onReport
        self.explained = State(initialValue: explained)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            Reveal(open: explained.wrappedValue) { reasons }
        }
        .background {
            if isLatest {
                Color.clear.glassStrip(in: shape)
            } else {
                shape.fill(Color.pkRow).overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// What the classifier and the correction rules said, line by line.
    private var reasons: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(ExplanationText.lines(entry.explanation).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 32)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private var row: some View {
        // A switch's other reading is its replacement: never-touch covers both.
        let readings = entry.kind == .layout ? [entry.replacement] : []
        // The list holds words: «во первых» is kept as «вопервых», as its undo learns it.
        let word = entry.kind == .hyphen ? entry.original.filter { $0 != " " } : entry.original
        let status = store.settings.words.validate(word, readings: readings)
        return HStack(spacing: 6) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.pkInk2)
                .frame(width: 16)
                .help(entry.kind.title)
            Group {
                Text(verbatim: entry.original).foregroundStyle(Color.pkInk3)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.pkInk3)
                Text(verbatim: entry.replacement)
                    .fontWeight(entry.undone ? .regular : .semibold)
                    .strikethrough(entry.undone, color: Color.pkInk3)
                    .foregroundStyle(entry.undone ? Color.pkInk3 : Color.pkInk)
            }
            .font(PK.Font.body)
            .lineLimit(1)
            .truncationMode(.tail)
            if entry.count > 1 {
                Text(verbatim: "×\(entry.count)")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
            Spacer(minLength: 2)
            switch status {
            case .ok, .frequent:
                RowIconButton(id: "fix-\(entry.id)-skip", symbol: "hand.raised", title: "Don't touch this word", nav: nav) {
                    store.update { _ = $0.words.add(word, readings: readings) }
                }
            case .duplicate:
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pkOK)
                    .frame(width: 24, height: 22)
                    .help(Text("Already on the list"))
                    .accessibilityLabel(Text("Already on the list"))
            case .empty, .invalid, .neverTouch, .tooShort:
                EmptyView()
            }
            RowIconButton(id: "fix-\(entry.id)-why", symbol: "questionmark.circle", title: "Why?", nav: nav,
                          selected: explained.wrappedValue) {
                explained.wrappedValue.toggle()
            }
            RowIconButton(id: "fix-\(entry.id)-report", symbol: "flag", title: "Report a word", nav: nav) {
                onReport(entry.original, entry.summary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }
}

/// A 24pt icon button at the end of a correction or dictation row.
struct RowIconButton: View {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    /// The strings table of the title: `Voice` for voice rows.
    var table: String?
    let nav: MenuNav
    /// A toggle that is on: its glyph wears the accent.
    var selected = false
    let run: () -> Void

    var body: some View {
        let lit = nav.highlighted == id
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit || selected ? Color.pkIndigoInk : Color.pkInk2)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.pkMist : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title, tableName: table))
        .accessibilityLabel(Text(title, tableName: table))
        .menuItem(id, nav: nav, run: run)
    }
}
