// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyInput
import SwiftUI

/// Drives the menu's entrance and exit; the view reads `shown`.
@MainActor
@Observable
final class MenuPresentation {
    var shown = false
}

/// The menu panel: borderless, never activates the app, but takes keys.
private final class MenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Reports its content size, so the panel can follow it.
private final class SizingHost<Root: View>: NSHostingView<Root> {
    var onSize: ((CGSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onSize?(fittingSize)
        }
    }
}

/// The menu under the status item, on an own panel: it enters with scale .92
/// from the top-right corner, closes on a click outside, Esc, a Space change or
/// when it loses the key, and works from the keyboard (arrows, Return, Space).
/// The hosting view exists only while the menu is open, so nothing runs when it is closed.
@MainActor
@Observable
final class MenuPanelController {
    private(set) var isOpen = false

    /// The status item's button in screen coordinates; set by the status item.
    @ObservationIgnored var anchor: () -> NSRect? = { nil }
    /// The status bar window; a click in it is the status item's business.
    @ObservationIgnored weak var statusWindow: NSWindow?
    @ObservationIgnored private var closedAt = Date.distantPast

    /// Open now, or closed a moment ago by the very click that is being handled
    /// (the panel lost the key first): the click must not open it again.
    var wasOpenForThisClick: Bool { isOpen || Date().timeIntervalSince(closedAt) < 0.25 }

    @ObservationIgnored private let sources: InputSources
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let pause: PauseState
    @ObservationIgnored private let launch: LaunchAtLogin
    @ObservationIgnored private let appModes: AppModeController
    @ObservationIgnored private let recents: RecentCorrections
    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private let actions: (MenuPanelController) -> MenuActions

    @ObservationIgnored private var panel: MenuPanel?
    @ObservationIgnored private var host: SizingHost<AnyView>?
    @ObservationIgnored private var nav = MenuNav()
    @ObservationIgnored private var presentation = MenuPresentation()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var teardown: DispatchWorkItem?

    /// Room around the menu for its shadow; the panel is this much larger on each side.
    private static let inset: CGFloat = 28
    private static let gap: CGFloat = 4

    init(sources: InputSources, store: SettingsStore, pause: PauseState, launch: LaunchAtLogin,
         appModes: AppModeController, recents: RecentCorrections, updates: Updates,
         actions: @escaping (MenuPanelController) -> MenuActions)
    {
        self.sources = sources
        self.store = store
        self.pause = pause
        self.launch = launch
        self.appModes = appModes
        self.recents = recents
        self.updates = updates
        self.actions = actions
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen, anchor() != nil else { return }
        teardown?.cancel()
        panel?.ignoresMouseEvents = false
        isOpen = true
        nav = MenuNav()
        presentation = MenuPresentation()

        var menuActions = actions(self)
        menuActions.close = { [weak self] in self?.close() }
        let root = MenuRoot(
            content: MenuContent(sources: sources, store: store, pause: pause, launch: launch, appModes: appModes,
                                 recents: recents, nav: nav, actions: menuActions, updates: updates),
            presentation: presentation, inset: Self.inset)
        let host = SizingHost(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        self.host = host

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = host
        host.onSize = { [weak self] size in self?.place(size: size) }
        place(size: host.fittingSize)
        panel.makeKeyAndOrderFront(nil)

        pause.tick()
        launch.refresh()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.pause.tick()
            }
        }
        installMonitors()
        // One turn later, so the view is drawn at scale .92 first.
        DispatchQueue.main.async { [presentation] in presentation.shown = true }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closedAt = Date()
        // Still on screen while it fades: no keys or clicks may reach it.
        panel?.ignoresMouseEvents = true
        ticker?.cancel()
        ticker = nil
        removeMonitors()
        presentation.shown = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            panel?.orderOut(nil)
            panel?.contentView = nil
            host = nil
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Panel

    private func makePanel() -> MenuPanel {
        let panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// Keeps the menu's top edge under the status item and its right edge near the item's.
    private func place(size: CGSize) {
        guard let panel, let anchorFrame = anchor(), size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset = Self.inset
        let menuWidth = size.width - 2 * inset
        let right = min(anchorFrame.maxX + 6, visible.maxX - 8)
        let left = max(visible.minX + 8, right - menuWidth)
        let top = anchorFrame.minY - Self.gap
        panel.setFrame(NSRect(x: left - inset, y: top + inset - size.height, width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        guard isOpen else { return true }
        let command = event.modifierFlags.contains(.command)
        if command, let key = event.charactersIgnoringModifiers {
            switch key {
            case ",": nav.actions["settings"]?.run(); return true
            case "q": nav.actions["quit"]?.run(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 125: nav.move(1)
        case 126: nav.move(-1)
        case 48: nav.move(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 123: nav.step(-1)
        case 124: nav.step(1)
        case 36, 76, 49: nav.activate()
        case 53: close()
        default: return false
        }
        return true
    }

    // MARK: Closing triggers

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(global)
        }
        // Clicks in our own windows: the panel itself and the status item are not "outside".
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if let self, event.window !== panel, event.window !== statusWindow { close() }
            return event
        }) {
            monitors.append(local)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }))
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }
}

/// The menu with its surface, shadow and entrance.
private struct MenuRoot: View {
    let content: MenuContent
    let presentation: MenuPresentation
    let inset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pkLiquidGlass) private var liquid

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: PK.Radius.menu, style: .continuous) }

    var body: some View {
        let shown = presentation.shown
        content
            .modifier(MenuSurface(shape: shape, liquid: liquid))
            .shadow(color: Color.pkGlow.opacity(0.35), radius: 18, x: 0, y: 10)
            .shadow(color: .black.opacity(0.14), radius: 24, x: 0, y: 12)
            .opacity(shown ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: shown)
            .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.92), anchor: .topTrailing)
            .animation(reduceMotion ? nil : PK.Motion.easeOut(0.45), value: shown)
            .padding(inset)
    }
}

private struct MenuSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let liquid: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *), liquid {
            content.pkGlass(in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5))
        }
    }
}
