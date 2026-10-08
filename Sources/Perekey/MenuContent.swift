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
    var showOnboarding: () -> Void = {}
    var showAbout: () -> Void = {}
    var quit: () -> Void = {}
    /// Opens the report form with this word filled in.
    var report: (String) -> Void = { _ in }
    var close: () -> Void = {}
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

    var order: [String] = []
    var highlighted: String?
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
    let step: (@MainActor (Int) -> Void)?
    let run: @MainActor () -> Void

    func body(content: Content) -> some View {
        content
            .preference(key: MenuOrderKey.self, value: [id])
            .onHover { nav.hover(id, $0) }
            .onAppear { nav.actions[id] = MenuNav.Action(run: run, step: step) }
            .onDisappear { nav.actions[id] = nil }
    }
}

private extension View {
    func menuItem(_ id: String, nav: MenuNav, step: (@MainActor (Int) -> Void)? = nil,
                  run: @escaping @MainActor () -> Void) -> some View {
        modifier(MenuItemModifier(id: id, nav: nav, step: step, run: run))
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

// MARK: - Menu

/// The menu panel's content: header, held-state card, mode, recent corrections,
/// switches, layouts and commands. Structure follows `pmenu` in `design/mockup.html`.
struct MenuContent: View {
    let sources: InputSources
    let store: SettingsStore
    let pause: PauseState
    let launch: LaunchAtLogin
    let appModes: AppModeController
    let recents: RecentCorrections
    /// `nil` hides the statistics line (snapshots, tests).
    var usage: UsageRecorder?
    var nav = MenuNav()
    var actions = MenuActions()
    /// `nil` hides "Check for Updates…" (snapshots).
    var updates: Updates?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last reason, so the card keeps its text while it folds away.
    private let lastReason = State<PauseReason?>(initialValue: nil)

    var body: some View {
        let heldReason = pause.current ?? lastReason.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            header
            Reveal(open: pause.current != nil) {
                if let reason = heldReason {
                    PauseCard(reason: reason, now: pause.now, nav: nav, onAction: { action(for: reason) })
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            modeCard
                .padding(.horizontal, 12)
            recentSection
            PKDivider(leading: 12, trailing: 12).padding(.top, 10)
            VStack(alignment: .leading, spacing: 2) {
                switchRow(
                    id: "pause", title: "Pause for 1 hour", subtitle: nil,
                    isOn: Binding(
                        get: { pause.isTimedPauseActive },
                        set: { $0 ? pause.pauseForOneHour() : pause.resumeTimed() }
                    )
                )
                LaunchAtLoginRow(launch: launch, nav: nav)
            }
            .padding(.vertical, 6)
            PKDivider(leading: 12, trailing: 12)
            LayoutsList(sources: sources, nav: nav, onSelected: actions.close)
                .padding(.vertical, 6)
            PKDivider(leading: 12, trailing: 12)
            commands
                .padding(.vertical, 6)
            if let usage, store.settings.statistics {
                usageLine(usage)
            }
        }
        .frame(width: 318)
        .onPreferenceChange(MenuOrderKey.self) { nav.order = $0 }
        .onAppear { lastReason.wrappedValue = pause.current }
        .onChange(of: pause.current) { _, new in
            if let new { lastReason.wrappedValue = new }
        }
        .environment(nav)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            CapsuleView(
                model: CapsuleModel(code: sources.currentLayout.map(sources.indicator(of:)) ?? "⌨", struck: !store.settings.autoswitch),
                dark: colorScheme == .dark, height: 30, fontSize: 17, animated: true, flash: recents.flashes
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(sources.currentLayout.map(sources.name(of:)) ?? String(localized: "No layout"))
                    .font(PK.Font.headline)
                    .foregroundStyle(Color.pkInk)
                Text(hintLine)
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous), glow: false)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
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
                Text("memory only").font(PK.Font.caption).foregroundStyle(Color.pkInk3)
            }
            .padding(.horizontal, 4)
            if recents.log.isEmpty {
                Text("Nothing yet. Corrections appear here as you type.")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    let latest = recents.log.latestStanding?.id
                    ForEach(recents.log.entries) { entry in
                        CorrectionRow(entry: entry, isLatest: entry.id == latest, store: store, nav: nav,
                                      onReport: { word in actions.report(word) })
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.easeOut(0.32), value: recents.log.entries)
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
            .foregroundStyle(Color.pkInk3)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(verbatim: text))
    }

    // MARK: Commands

    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuCommandRow(id: "settings", title: "Settings…", shortcut: "⌘,", nav: nav, run: actions.openSettings)
            if let updates {
                UpdatesMenuRow(updates: updates, nav: nav, close: actions.close)
            }
            MenuCommandRow(id: "onboarding", title: "How to Use Perekey", shortcut: nil, nav: nav, run: actions.showOnboarding)
            MenuCommandRow(id: "about", title: "About Perekey", shortcut: nil, nav: nav, run: actions.showAbout)
            MenuCommandRow(id: "quit", title: "Quit Perekey", shortcut: "⌘Q", nav: nav, run: actions.quit)
        }
    }

    private func action(for reason: PauseReason) {
        switch reason {
        case .timed: pause.resumeTimed()
        case .appOff: pause.onTurnOnHere?()
        case .secureInput, .passwordField: break
        }
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
    var shortcut: String?
    var checked = false
    var badge = false
    var enabled = true
    let nav: MenuNav
    let run: () -> Void

    var body: some View {
        let hot = enabled && nav.highlighted == id
        Button(action: run) {
            HStack {
                Text(title).font(PK.Font.body)
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
            .foregroundStyle(hot ? Color.white : Color.pkInk)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hot ? Color.pkIndigoFill : .clear))
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .menuItem(id, nav: nav, run: { if enabled { run() } })
    }
}

/// "Check for Updates…", or the gentle reminder of a found update. Hidden when
/// a profile forbids updates; dimmed in a build that cannot update itself.
struct UpdatesMenuRow: View {
    let updates: Updates
    let nav: MenuNav
    let close: () -> Void

    var body: some View {
        let policy = updates.policy
        if policy.state != .managedOff {
            if let version = updates.pendingVersion {
                MenuCommandRow(id: "updates", title: "Install Update \(version)…", shortcut: nil, badge: true,
                               enabled: policy.canCheckNow, nav: nav, run: run)
            } else {
                MenuCommandRow(id: "updates", title: "Check for Updates…", shortcut: nil,
                               enabled: policy.canCheckNow, nav: nav, run: run)
            }
        }
    }

    private func run() {
        close()
        updates.checkNow()
    }
}

/// The enabled layouts with a checkmark on the selected one; a click selects.
struct LayoutsList: View {
    let sources: InputSources
    let nav: MenuNav
    let onSelected: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.layouts, id: \.id) { layout in
                MenuCommandRow(id: "layout-\(layout.id.rawValue)", title: LocalizedStringKey(sources.name(of: layout.id)),
                               checked: sources.currentLayout == layout.id, nav: nav) {
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
    let onReport: (String) -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        // A switch's other reading is its replacement: never-touch covers both.
        let readings = entry.kind == .layout ? [entry.replacement] : []
        let status = store.settings.words.validate(entry.original, readings: readings)
        HStack(spacing: 6) {
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
            Spacer(minLength: 2)
            switch status {
            case .ok, .frequent:
                RowIconButton(id: "fix-\(entry.id)-skip", symbol: "hand.raised", title: "Don't touch this word", nav: nav) {
                    store.update { _ = $0.words.add(entry.original, readings: readings) }
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
            RowIconButton(id: "fix-\(entry.id)-report", symbol: "flag", title: "Report a word", nav: nav) {
                onReport(entry.original)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background {
            if isLatest {
                Color.clear.glassStrip(in: shape)
            } else {
                shape.fill(Color.pkRow).overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A 24pt icon button at the end of a correction row.
private struct RowIconButton: View {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    let nav: MenuNav
    let run: () -> Void

    var body: some View {
        let lit = nav.highlighted == id
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? Color.pkIndigoInk : Color.pkInk2)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.pkMist : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .menuItem(id, nav: nav, run: run)
    }
}
