// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput
import PerekeyVoiceCore
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

/// What the capsule shows of a call being recorded: ● and the time. Empty
/// without voice.
@MainActor
@Observable
final class CallIndicatorModel {
    var timeline: CallTimeline?
    var paused = false

    var elapsed: Double { timeline?.offset(of: mach_absolute_time()) ?? 0 }
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
    let call: CallIndicatorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let model = capsuleModel(sources: sources, store: store, pause: pause)
        let style = store.settings.menuBarIcon
        HStack(spacing: 4) {
            if call.timeline != nil {
                CallBadge(call: call)
            }
            if style == .capsule {
                CapsuleView(
                    model: model,
                    dark: scheme == .dark, animated: true,
                    pressed: state.pressed, open: menu.isOpen, flash: recents.flashes
                )
            } else {
                MenuBarGlyph(style: style, model: model, icon: sources.currentLayout.flatMap(sources.icon(of:)))
                    .modifier(GlyphMotion(pressed: state.pressed, open: menu.isOpen, flash: recents.flashes))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// What the capsule does for a press, an open menu and a correction, for the
/// plain styles: a small scale, a dimmed press, and a pulse of the item.
private struct GlyphMotion: ViewModifier {
    let pressed: Bool
    let open: Bool
    let flash: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let reduce = reduceMotion
        return content
            .opacity(pressed || open ? 0.6 : 1)
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .keyframeAnimator(initialValue: 1.0, trigger: flash) { view, level in
                view.scaleEffect(reduce ? 1 : level).opacity(reduce ? 1 - (level - 1) * 4 : 1)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.18, duration: 0.12)
                    CubicKeyframe(1.0, duration: 0.48)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : PK.Motion.spring, value: pressed)
    }
}

/// ● and the time of a call being recorded, left of the capsule.
private struct CallBadge: View {
    let call: CallIndicatorModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 3) {
                Circle()
                    .fill(call.paused ? Color.secondary : Color.red)
                    .frame(width: 7, height: 7)
                Text(verbatim: callClock(call.elapsed))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
        }
    }
}

/// «1:02:05» or «12:34».
func callClock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
    /// Files dropped on the item; false refuses them. Nil takes no drops.
    var onDrop: (([URL]) -> Bool)? {
        didSet {
            if onDrop == nil { unregisterDraggedTypes() } else { registerForDraggedTypes([.fileURL]) }
        }
    }
    /// Whether a file being dragged would be taken, before the drop.
    var accepts: (URL) -> Bool = { _ in false }

    private func files(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && files(sender).contains(where: accepts) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(files(sender)) ?? false
    }

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
    private let call: CallIndicatorModel
    private var shrink: DispatchWorkItem?

    /// - Parameters:
    ///   - drop: files dropped on the item (voice: to transcribe); false refuses them.
    ///   - accepts: whether a dragged file would be taken.
    init(sources: InputSources, store: SettingsStore, pause: PauseState, recents: RecentCorrections,
         menu: MenuPanelController, call: CallIndicatorModel, drop: (([URL]) -> Bool)? = nil,
         accepts: @escaping (URL) -> Bool = { _ in false })
    {
        self.sources = sources
        self.call = call
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
            sources: sources, store: store, pause: pause, recents: recents, state: state, menu: menu, call: call))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        host.onSize = { [weak self] width in self?.fit(width: width) }
        button.addSubview(host)

        let click = ClickView()
        click.translatesAutoresizingMaskIntoConstraints = false
        click.onDown = { [weak self] in self?.pressDown() }
        click.onUp = { [weak self] in self?.state.pressed = false }
        click.accepts = accepts
        click.onDrop = drop
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

        menu.statusWindow = button.window
        // A hidden item has no anchor. Its window may also be off screen while a
        // full-screen app hides the menu bar, and the menu still opens then.
        menu.anchor = { [weak self, weak button] in
            guard let self, statusItem.isVisible, let button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        observeVoiceOverState()
        observeVisibility()
    }

    /// Shows or hides the item as the setting and the situation say. A hidden
    /// item has no anchor, so the menu does not open: Perekey opens its
    /// Settings when it is launched again instead (`applicationShouldHandleReopen`).
    private func observeVisibility() {
        let visible = withObservationTracking {
            MenuBarPolicy.isVisible(store.settings.menuBarVisibility, MenuBarSituation(
                paused: pause.current != nil, autoswitchOff: !store.settings.autoswitch,
                recordingCall: call.timeline != nil))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeVisibility() }
        }
        if !visible { menu.close() }
        statusItem.isVisible = visible
    }

    private func pressDown() {
        state.pressed = true
        // A click that closed the menu by taking its key must not reopen it.
        if menu.wasOpenForThisClick {
            menu.close()
        } else {
            menu.open()
        }
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
            if call.timeline != nil {
                parts.append(call.paused ? String(localized: "Call recording paused", table: "Voice")
                                         : String(localized: "Recording a call", table: "Voice"))
            }
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
