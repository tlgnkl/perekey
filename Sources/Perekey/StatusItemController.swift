// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput
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

/// The press state of the status item, read by the capsule.
@MainActor
@Observable
final class StatusItemModel {
    var pressed = false
}

/// The live capsule in the menu bar. SwiftUI re-renders it only when the layout,
/// the settings, the pause state, the press or the menu change.
private struct StatusCapsuleView: View {
    let sources: InputSources
    let store: SettingsStore
    let pause: PauseState
    let recents: RecentCorrections
    let state: StatusItemModel
    let menu: MenuPanelController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CapsuleView(
            model: capsuleModel(sources: sources, store: store, pause: pause),
            dark: scheme == .dark, animated: true,
            pressed: state.pressed, open: menu.isOpen, flash: recents.flashes
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// Reports its content size, so the item can follow it.
private final class CapsuleHost: NSHostingView<StatusCapsuleView> {
    var onSize: ((CGFloat) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onSize?(intrinsicContentSize.width)
        }
    }

    /// The click view above takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Catches the mouse over the capsule: the menu opens on mouse down, like a native
/// one, and the capsule stays pressed until the button comes up.
private final class ClickView: NSView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func rightMouseDown(with event: NSEvent) { onDown?() }
    override func rightMouseUp(with event: NSEvent) { onUp?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the `NSStatusItem` with the live capsule (instead of `MenuBarExtra`, which
/// can only show an image) and opens the menu panel under it.
@MainActor
final class StatusItemController {
    private static let margin: CGFloat = 3

    private let statusItem: NSStatusItem
    private let state = StatusItemModel()
    private let menu: MenuPanelController
    private let sources: InputSources
    private let store: SettingsStore
    private let pause: PauseState
    private var shrink: DispatchWorkItem?

    init(sources: InputSources, store: SettingsStore, pause: PauseState, recents: RecentCorrections,
         menu: MenuPanelController)
    {
        self.sources = sources
        self.store = store
        self.pause = pause
        self.menu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.title = ""
        button.target = self
        button.action = #selector(performPress)
        button.setAccessibilityRole(.menuButton)
        button.setAccessibilityLabel("Perekey")
        button.setAccessibilityHelp(String(localized: "Opens the Perekey menu"))

        let host = CapsuleHost(rootView: StatusCapsuleView(
            sources: sources, store: store, pause: pause, recents: recents, state: state, menu: menu))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        host.onSize = { [weak self] width in self?.fit(width: width) }
        button.addSubview(host)

        let click = ClickView()
        click.translatesAutoresizingMaskIntoConstraints = false
        click.onDown = { [weak self] in self?.pressDown() }
        click.onUp = { [weak self] in self?.state.pressed = false }
        button.addSubview(click)

        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            host.topAnchor.constraint(equalTo: button.topAnchor),
            host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            click.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            click.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            click.topAnchor.constraint(equalTo: button.topAnchor),
            click.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        fit(width: host.intrinsicContentSize.width)

        menu.anchor = { [weak button] in
            guard let button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        observeVoiceOverState()
    }

    private func pressDown() {
        state.pressed = true
        menu.toggle()
    }

    /// VoiceOver's "press" lands here; there is no mouse up for it.
    @objc private func performPress() {
        guard !state.pressed else { return }
        menu.toggle()
    }

    /// The item grows at once (the capsule springs open inside it) and shrinks
    /// after the spring has settled.
    private func fit(width: CGFloat) {
        guard width > 0 else { return }
        let target = ceil(width) + 2 * Self.margin
        shrink?.cancel()
        if target >= statusItem.length || statusItem.length == NSStatusItem.variableLength {
            statusItem.length = target
        } else {
            let work = DispatchWorkItem { [weak self] in self?.statusItem.length = target }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }

    /// The button speaks for the capsule: layout and state, kept up to date by observation.
    private func observeVoiceOverState() {
        let value = withObservationTracking {
            var parts = [sources.currentLayout.map(sources.name(of:)) ?? String(localized: "No layout")]
            if let reason = pause.current {
                parts.append(reason.title(now: pause.now))
            } else {
                parts.append(store.settings.autoswitch ? String(localized: "Automatic switching is on")
                                                       : String(localized: "Automatic switching is off"))
            }
            return parts.joined(separator: ". ")
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVoiceOverState() }
        }
        statusItem.button?.setAccessibilityValue(value)
    }
}
