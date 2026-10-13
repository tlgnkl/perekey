// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyInput
import PerekeyVoice
import SwiftUI

/// The dictation HUD: a glass capsule at the caret that follows
/// `VoiceController.hud`. A panel that never takes focus and, outside its
/// buttons, no mouse events either. Without a caret it sits at the bottom
/// centre of the screen the pointer is on.
///
/// The caret is looked up once per dictation, on the AX thread with the
/// timeout of `CaretLocator`; the capsule keeps that place while the state
/// changes and only follows its own size.
@MainActor
final class VoiceHUDController {
    struct Actions {
        var openMicrophoneSettings: () -> Void
        var openAccessibilitySettings: () -> Void
        var openVoiceSettings: () -> Void
    }

    private static let exit: TimeInterval = 0.22

    private let voice: VoiceController
    private let actions: Actions
    private let locator = CaretLocator()
    private let model = VoiceHUDModel(DictationHUDPresentation(message: .recording))
    private var panel: VoiceHUDPanel?
    private var follow: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var generation = 0
    private var previous: DictationHUDPresentation?
    /// Where the caret was when this dictation began; nil when it could not be found.
    private var caret: CGRect?
    /// The caret is being looked up; the capsule shows when it answers.
    private var locating = false

    init(voice: VoiceController, actions: Actions) {
        self.voice = voice
        self.actions = actions
        let updates = voice.hudUpdates()
        follow = Task { [weak self] in
            for await state in updates {
                guard let self else { return }
                self.handle(state)
            }
        }
    }

    /// Voice went off: the HUD goes with it, at once.
    func stop() {
        follow?.cancel()
        follow = nil
        generation += 1
        locating = false
        hideTask?.cancel()
        stopMouseMonitor()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - States

    private func handle(_ state: DictationHUDState) {
        let presentation = DictationHUDPresentation(state, hasText: voice.last.map { !$0.isPrivate } ?? false)
        defer { previous = presentation }
        guard let presentation else {
            hide()
            return
        }
        // A dictation begins when the meter appears after a state without one.
        let begins = presentation.meter != nil && previous?.meter == nil
        if DictationHUDPresentation.announces(presentation, after: previous) {
            Self.announce(presentation.spokenText)
        }
        model.presentation = presentation
        scheduleHide(after: presentation.hidesAfter)
        if locating {
            // The lookup in flight shows the capsule with the latest state.
        } else if begins || panel?.isVisible != true {
            if begins { caret = nil }
            show(locate: begins)
        } else if layoutKey != LayoutKey(presentation) {
            // The timer and the level tick ~20 times a second and change no size.
            place()
        }
    }

    /// What sizes the capsule: the message, the buttons, the width of the timer.
    private struct LayoutKey: Equatable {
        var message: DictationHUDPresentation.Message
        var buttons: [DictationHUDPresentation.Button]
        var timerDigits: Int?

        init(_ presentation: DictationHUDPresentation) {
            message = presentation.message
            buttons = presentation.buttons
            timerDigits = presentation.meter?.timerText.count
        }
    }

    private var layoutKey: LayoutKey?
    private var mouseMonitor: Any?

    private func show(locate: Bool) {
        generation += 1
        let mine = generation
        guard locate else {
            present()
            return
        }
        locating = true
        locator.caretRect { [weak self] rect in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.locating = false
                self.caret = rect
                self.present()
            }
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        startMouseMonitor()
        let wasVisible = panel.isVisible && model.visible
        place()
        if !wasVisible {
            model.visible = false
            panel.orderFrontRegardless()
            setVisible(true)
        }
    }

    // MARK: - Place

    private func place() {
        guard let panel else { return }
        layoutKey = LayoutKey(model.presentation)
        let size = NSHostingView(rootView: VoiceHUDContent(presentation: model.presentation)).fittingSize
        let origin: CGPoint
        if let caret, let screen = screen(containing: CGPoint(x: caret.midX, y: caret.midY)) {
            origin = HintPlacement.origin(size: size, caret: caret, visible: screen.visibleFrame)
        } else {
            let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            origin = HintPlacement.bottomCenterOrigin(size: size, visible: screen.visibleFrame)
        }
        let inset = VoiceHUDMetrics.shadowInset
        panel.setFrame(CGRect(origin: origin, size: size).insetBy(dx: -inset, dy: -inset), display: true)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    // MARK: - Show and hide

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func setVisible(_ visible: Bool) {
        if Self.reduceMotion {
            withAnimation(.linear(duration: 0.01)) { model.visible = visible }
        } else if visible {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.45)) { model.visible = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.visible = false }
        }
    }

    /// The panel ignores the mouse, so the capsule and the shadow around it never
    /// swallow a click meant for the app below. It listens only while the
    /// pointer is over a button.
    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
    }

    private func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel?.ignoresMouseEvents = true
    }

    private func followPointer() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation
        let over = model.buttonFrames.contains { frame in
            CGRect(x: panel.frame.minX + frame.minX, y: panel.frame.maxY - frame.maxY,
                   width: frame.width, height: frame.height).contains(point)
        }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        generation += 1
        locating = false
        let mine = generation
        guard let panel, panel.isVisible else { return }
        setVisible(false)
        stopMouseMonitor()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.reduceMotion ? 20 : Int(Self.exit * 1000)))
            guard let self, self.generation == mine, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// A final state goes after `seconds`; a pointer over the capsule holds it.
    private func scheduleHide(after seconds: TimeInterval?) {
        hideTask?.cancel()
        hideTask = nil
        guard let seconds else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, let self, self.pointerIsOver {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private var pointerIsOver: Bool {
        guard let panel, panel.isVisible else { return false }
        let inset = VoiceHUDMetrics.shadowInset
        return panel.frame.insetBy(dx: inset, dy: inset).contains(NSEvent.mouseLocation)
    }

    // MARK: - Buttons

    private func perform(_ button: DictationHUDPresentation.Button) {
        switch button {
        case .cancel, .pasteAsSaid: voice.voice(.cancel)
        case .paste: voice.pasteLast()
        case .copy: copyLast()
        case .openMicrophoneSettings: actions.openMicrophoneSettings()
        case .openAccessibilitySettings: actions.openAccessibilitySettings()
        case .openVoiceSettings: actions.openVoiceSettings()
        }
    }

    private func copyLast() {
        guard let last = voice.last, !last.isPrivate else { return }
        let text = last.text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let copied = DictationHUDPresentation(message: .copied, hidesAfter: DictationHUDPresentation.Lifetime.confirmation)
        model.presentation = copied
        previous = copied
        Self.announce(copied.spokenText)
        scheduleHide(after: copied.hidesAfter)
        place()
    }

    // MARK: - VoiceOver

    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func makePanel() -> VoiceHUDPanel {
        let view = VoiceHUDView(model: model, perform: { [weak self] in self?.perform($0) })
        let panel = VoiceHUDPanel(rootView: view)
        panel.hostingView.model = model
        return panel
    }
}

/// Hosting view that passes every click through except over a button.
private final class VoiceHUDHostingView: NSHostingView<VoiceHUDView> {
    var model: VoiceHUDModel?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let model else { return nil }
        let local = convert(point, from: superview)
        let y = isFlipped ? local.y : bounds.height - local.y
        guard model.buttonFrames.contains(where: { $0.contains(CGPoint(x: local.x, y: y)) }) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Never key, never main, never active: a click on a button runs it and the
/// app in front keeps the keyboard.
private final class VoiceHUDPanel: NSPanel {
    let hostingView: VoiceHUDHostingView

    init(rootView: VoiceHUDView) {
        hostingView = VoiceHUDHostingView(rootView: rootView)
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
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
