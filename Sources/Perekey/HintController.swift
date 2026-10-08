// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyInput
import SwiftUI

/// The hint at the caret: what Perekey just corrected, with «Undo», or what an
/// undo taught it, with «Forget». A panel that never takes focus and, outside
/// its button, no mouse events either.
///
/// Self-contained: the engine side calls `show`/`showLearned`/`hide` with
/// strings and closures.
@MainActor
final class HintController {
    /// Seconds the hint stays; the timer stands still while the pointer is over it.
    static let lifetime: TimeInterval = 3
    private static let tick: TimeInterval = 0.1

    private let locator = CaretLocator()
    private let model = HintModel(content: .learned(word: ""))
    private var panel: HintPanel?
    private var generation = 0
    private var timer: Timer?
    private var remaining: TimeInterval = 0
    private var currentAction: (() -> Void)?
    private var publishedButtonFrame: CGRect?

    /// The button's frame in CG global coordinates (top-left origin of the
    /// main display) while the hint shows, nil once it goes. The engine
    /// tells a click on it from a click that moves the caret.
    var onButtonFrame: ((CGRect?) -> Void)?

    init() {
        model.onButtonFrameChange = { [weak self] in self?.publishButtonFrame() }
    }

    /// After a correction: `original` struck out, `replacement` underlined, an
    /// «Undo» chip that calls `onUndo`.
    func show(original: String, replacement: String, onUndo: @escaping () -> Void) {
        present(.corrected(original: original, replacement: replacement), action: onUndo)
    }

    /// After an undo with learning: «Remembered “word” · Forget».
    func showLearned(word: String, onForget: @escaping () -> Void) {
        present(.learned(word: word), action: onForget)
    }

    func hide() {
        generation += 1
        dismiss()
    }

    // MARK: -

    private func present(_ content: HintContent, action: @escaping () -> Void) {
        generation += 1
        let mine = generation
        currentAction = action
        locator.caretRect { [weak self] rect in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.place(content, caret: rect)
            }
        }
    }

    private func place(_ content: HintContent, caret: CGRect?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible && model.visible
        model.content = content

        let host = panel.hostingView
        host.layoutSubtreeIfNeeded()
        let full = host.fittingSize
        let inset = HintMetrics.shadowInset
        let bubble = CGSize(width: full.width - 2 * inset, height: full.height - 2 * inset)

        let origin: CGPoint
        if let caret, let screen = screen(containing: CGPoint(x: caret.midX, y: caret.midY)) {
            origin = HintPlacement.origin(size: bubble, caret: caret, visible: screen.visibleFrame)
        } else {
            let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            origin = HintPlacement.fallbackOrigin(size: bubble, visible: screen.visibleFrame)
        }
        panel.setFrame(NSRect(x: origin.x - inset, y: origin.y - inset, width: full.width, height: full.height), display: true)

        if !panel.isVisible {
            model.visible = false
            panel.orderFrontRegardless()
        }
        if !wasVisible { setVisible(true) }
        remaining = Self.lifetime
        startTimer()
        publishButtonFrame()
    }

    private func publishButtonFrame() {
        var frame: CGRect?
        if let panel, panel.isVisible, currentAction != nil, model.buttonFrame != .zero,
           let main = NSScreen.screens.first
        {
            // The hosting view fills the panel and has a top-left origin.
            let button = model.buttonFrame
            frame = CGRect(x: panel.frame.minX + button.minX, y: main.frame.maxY - panel.frame.maxY + button.minY,
                           width: button.width, height: button.height)
        }
        guard frame != publishedButtonFrame else { return }
        publishedButtonFrame = frame
        onButtonFrame?(frame)
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        currentAction = nil
        publishButtonFrame()
        guard let panel, panel.isVisible else { return }
        setVisible(false)
        let mine = generation
        // Closes after the .2 s exit unless something new came in meanwhile.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reduceMotion ? 20 : 220))
            guard let self, self.generation == mine, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func setVisible(_ visible: Bool) {
        if Self.reduceMotion {
            withAnimation(.linear(duration: 0.01)) { model.visible = visible }
        } else if visible {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.55)) { model.visible = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.visible = false }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        guard let panel else { return }
        // Paused while hovered.
        if panel.frame.insetBy(dx: HintMetrics.shadowInset, dy: HintMetrics.shadowInset).contains(NSEvent.mouseLocation) {
            return
        }
        remaining -= Self.tick
        if remaining <= 0 {
            generation += 1
            dismiss()
        }
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func makePanel() -> HintPanel {
        let view = HintView(model: model) { [weak self] in
            guard let self else { return }
            let action = self.currentAction
            self.hide()
            action?()
        }
        let panel = HintPanel(rootView: view, model: model)
        return panel
    }
}

/// Hosting view that passes every click through except over the button.
private final class HintHostingView: NSHostingView<HintView> {
    var model: HintModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model else { return nil }
        let local = convert(point, from: superview)
        let y = isFlipped ? local.y : bounds.height - local.y
        guard model.buttonFrame.contains(CGPoint(x: local.x, y: y)) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class HintPanel: NSPanel {
    let hostingView: HintHostingView

    init(rootView: HintView, model: HintModel) {
        hostingView = HintHostingView(rootView: rootView)
        hostingView.model = model
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentView = hostingView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
