// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// The hint at the caret: what Perekey just corrected, with «Undo», what an
/// undo taught it, with «Forget», or the user's own retype. A panel that never
/// takes focus and, outside its button, no mouse events either.
///
/// Self-contained: the engine side calls `show`/`showRetyped`/`showLearned`/
/// `hide` with strings and closures. A new hint while one shows glides to its
/// place and morphs; the panel is the union of the two bubbles meanwhile, and
/// SwiftUI animates the bubble inside it.
@MainActor
final class HintController {
    private static let tick: TimeInterval = 0.1
    private static let glide: TimeInterval = 0.45
    /// How long an opened explanation stays after the press.
    private static let explanationSeconds: TimeInterval = 10

    private let locator = CaretLocator()
    private let model = HintModel(content: .learned(word: ""))
    private var panel: HintPanel?
    private var generation = 0
    private var timer: Timer?
    private var lifetime = HintLifetime(now: 0)
    private var keyMonitor: Any?
    private var currentAction: (() -> Void)?
    private var publishedButtonFrame: CGRect?
    /// The bubble's target in screen coordinates (bottom-left origin).
    private var bubbleScreen: CGRect = .zero
    /// Everything the bubble may cover while it glides: the panel's content.
    private var occupied: CGRect = .zero

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
        alwaysFixAction = nil
        present(.corrected(original: original, replacement: replacement), action: onUndo)
    }

    /// After the user's own retype: «word · ⌥ — revert». No button.
    /// `onAlwaysFix` offers «Always fix»; it runs when the user presses it.
    func showRetyped(original: String, word: String, shortcut: String?, why: HintWhy?,
                     onAlwaysFix: (() -> Void)? = nil)
    {
        alwaysFixAction = onAlwaysFix
        present(.retyped(original: HintMetrics.shortened(original), word: HintMetrics.shortened(word),
                         shortcut: shortcut, why: why, offersAlways: onAlwaysFix != nil), action: nil)
    }

    /// After «Always fix»: «Will always fix “word” · Undo».
    func showAlwaysFixed(word: String, onUndo: @escaping () -> Void) {
        alwaysFixAction = nil
        present(.alwaysFixed(word: HintMetrics.shortened(word)), action: onUndo)
    }

    /// After an undo that took a word off the list. No button.
    func showAlwaysFixWithdrawn(word: String) {
        alwaysFixAction = nil
        present(.alwaysFixWithdrawn(word: HintMetrics.shortened(word)), action: nil)
    }

    /// After an undo with learning: «Remembered “word” · Forget».
    func showLearned(word: String, onForget: @escaping () -> Void) {
        alwaysFixAction = nil
        present(.learned(word: word), action: onForget)
    }

    func hide() {
        alwaysFixAction = nil
        generation += 1
        dismiss()
    }

    // MARK: -

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private func present(_ content: HintContent, action: (() -> Void)?) {
        generation += 1
        let mine = generation
        currentAction = action
        locator.caretRect { [weak self] rect in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.place(content, caret: rect, expanded: false)
            }
        }
    }

    /// «Why?» was pressed: the explanation opens under the line, and the hint
    /// stays a while longer.
    private func explain() {
        guard model.visible, !model.expanded, case let .retyped(_, _, _, why, _) = model.content, why != nil else { return }
        lifetime.hold(for: Self.explanationSeconds, at: Self.now)
        place(model.content, caret: lastCaret, expanded: true)
    }

    private func place(_ content: HintContent, caret: CGRect?, expanded: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let wasVisible = panel.isVisible && model.visible
        // The same hint, grown: no new strip, no new clock.
        let opens = expanded && wasVisible
        lastCaret = caret
        buttonActive = true

        // The size the new content needs, from a copy laid out off screen.
        let measured = HintModel(content: content)
        measured.expanded = expanded
        let size = NSHostingView(rootView: HintBubbleContent(model: measured, action: {})).fittingSize

        let target: CGPoint
        if let caret, let screen = screen(containing: CGPoint(x: caret.midX, y: caret.midY)) {
            target = HintPlacement.origin(size: size, caret: caret, visible: screen.visibleFrame)
        } else {
            let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            target = HintPlacement.fallbackOrigin(size: size, visible: screen.visibleFrame)
        }
        let newBubble = CGRect(origin: target, size: size)
        let inset = HintMetrics.shadowInset
        remainingGlide += 1
        let glideRun = remainingGlide

        if wasVisible {
            // Cover old and new in one panel, keep the bubble where it is, then
            // let SwiftUI carry it to the new place and morph its content.
            let oldBubble = bubbleScreen
            occupied = occupied.union(oldBubble).union(newBubble)
            let stage = occupied.insetBy(dx: -inset, dy: -inset)
            panel.setFrame(stage, display: true)
            withAnimation(nil) { model.bubble = local(oldBubble, in: stage) }
            bubbleScreen = newBubble
            gliding = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.remainingGlide == glideRun else { return }
                    let reduced = Self.reduceMotion
                    withAnimation(reduced ? .linear(duration: 0.01) : .timingCurve(0.16, 1, 0.3, 1, duration: Self.glide)) {
                        self.model.content = content
                        self.model.expanded = expanded
                        self.model.bubble = self.local(newBubble, in: stage)
                    }
                    if !opens { self.model.strip.play() }
                    self.settle(after: reduced ? 0.05 : Self.glide + 0.05, run: glideRun)
                }
            }
        } else {
            bubbleScreen = newBubble
            occupied = newBubble
            gliding = false
            // The last scene's button is gone; the new one reports its own place.
            model.buttonFrame = .zero
            let stage = newBubble.insetBy(dx: -inset, dy: -inset)
            model.content = content
            model.expanded = expanded
            panel.setFrame(stage, display: true)
            withAnimation(nil) { model.bubble = local(newBubble, in: stage) }
            model.visible = false
            model.strip.rest(at: 0)
            panel.orderFrontRegardless()
            setVisible(true)
            model.strip.play(delay: 0.12)
        }
        if opens {
            // Keep the clock the press set.
        } else if wasVisible {
            lifetime.restart(at: Self.now)
        } else {
            lifetime = HintLifetime(now: Self.now)
        }
        startKeyMonitor()
        startTimer()
        publishButtonFrame()
    }

    private var remainingGlide = 0
    private var lastCaret: CGRect?
    private var alwaysFixAction: (() -> Void)?
    /// The hint is showing and its buttons take clicks.
    private var buttonActive = false
    /// The bubble is moving: its button has no stable place, so it takes no clicks.
    private var gliding = false {
        didSet { model.gliding = gliding }
    }

    /// Shrinks the panel to the bubble once it arrived.
    private func settle(after delay: TimeInterval, run: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.remainingGlide == run, let panel = self.panel, panel.isVisible else { return }
            let inset = HintMetrics.shadowInset
            let stage = self.bubbleScreen.insetBy(dx: -inset, dy: -inset)
            self.occupied = self.bubbleScreen
            self.gliding = false
            panel.setFrame(stage, display: true)
            withAnimation(nil) { self.model.bubble = self.local(self.bubbleScreen, in: stage) }
            self.publishButtonFrame()
        }
    }

    /// A screen rect (bottom-left origin) in the stage's top-left coordinates.
    private func local(_ rect: CGRect, in stage: CGRect) -> CGRect {
        CGRect(x: rect.minX - stage.minX, y: stage.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func publishButtonFrame() {
        var frame: CGRect?
        if let panel, panel.isVisible, !gliding, buttonActive, model.content.hasButton, !model.expanded,
           model.buttonFrame != .zero,
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
        // A glide or a delayed strip still on its way must not run on a hiding panel.
        remainingGlide += 1
        gliding = false
        model.strip.rest(at: 1, style: model.strip.style)
        timer?.invalidate()
        timer = nil
        stopKeyMonitor()
        currentAction = nil
        buttonActive = false
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

    // MARK: - Lifetime

    /// Key presses elsewhere tell the timer how the user types. Installed only
    /// while the hint shows. Only the kind of key is kept, in memory, never
    /// the character.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Perekey's own retype and the replay of held keys are no typing of
            // the user's now: the second word of «ghbdtn vbh » would end its hint.
            if let cgEvent = event.cgEvent,
               SyntheticMark(userData: cgEvent.getIntegerValueField(.eventSourceUserData)) != nil
            {
                return
            }
            let key = HintKey.classify(keyCode: event.keyCode, character: event.characters?.first,
                                       isShortcut: !event.modifierFlags.intersection([.command, .control]).isEmpty)
            MainActor.assumeIsolated { self?.keyPressed(key) }
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func keyPressed(_ key: HintKey) {
        lifetime.record(key, at: Self.now)
        expireIfDone()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    private func step() {
        let now = Self.now
        lifetime.setHovering(bubbleScreen.contains(NSEvent.mouseLocation), at: now)
        expireIfDone()
    }

    private func expireIfDone() {
        guard lifetime.isExpired(at: Self.now) else { return }
        generation += 1
        dismiss()
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func makePanel() -> HintPanel {
        let view = HintView(model: model, action: { [weak self] in
            guard let self else { return }
            let action = self.currentAction
            self.hide()
            action?()
        }, explain: { [weak self] in self?.explain() }, alwaysFix: { [weak self] in self?.alwaysFixAction?() })
        return HintPanel(rootView: view, model: model)
    }
}

/// Hosting view that passes every click through except over the button.
private final class HintHostingView: NSHostingView<HintView> {
    var model: HintModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model, !model.gliding else { return nil }
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
