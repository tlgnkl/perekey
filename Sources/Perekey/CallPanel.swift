// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// The small floating panel of a call recording: the source picker before
/// the start, then the time, the levels of the two tracks, «Пауза» and
/// «Стоп». It floats over every app and never takes the focus from the
/// call while it records.
@MainActor
final class CallPanelController {
    private let model: CallRecordingController
    private var panel: CallPanelWindow?
    /// Placed once: then the panel stays where the user dragged it.
    private var placed = false

    init(model: CallRecordingController) {
        self.model = model
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Picking the source takes the keyboard; recording and a notice do
        // not, and give it back to the call at once.
        panel.takesKeys = !model.isRecording && model.notice == nil
        if !panel.takesKeys, panel.isKeyWindow {
            let frame = panel.frame
            panel.orderOut(nil)
            panel.setFrame(frame, display: false)
        }
        fit(panel)
        if panel.takesKeys {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> CallPanelWindow {
        let panel = CallPanelWindow()
        let host = NSHostingView(rootView: CallPanelView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// Under the menu bar at the right, where the status item is; then
    /// wherever the user drags it, its top edge kept as the content changes.
    private func fit(_ panel: CallPanelWindow) {
        let size = panel.contentView?.fittingSize ?? CGSize(width: 300, height: 140)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if placed, onScreen {
            let top = panel.frame.maxY
            let frame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: size))
            panel.setFrame(CGRect(x: panel.frame.minX, y: top - frame.height, width: frame.width,
                                  height: frame.height), display: true)
            return
        }
        guard let screen = NSScreen.main else { return }
        placed = true
        let visible = screen.visibleFrame
        let frame = panel.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        panel.setFrame(CGRect(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 12,
                              width: frame.width, height: frame.height), display: true)
    }
}

private final class CallPanelWindow: NSPanel {
    var takesKeys = false

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 300, height: 140),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        setAccessibilityLabel(voiceString("Call recording"))
    }

    override var canBecomeKey: Bool { takesKeys }
    override var canBecomeMain: Bool { false }
}

struct CallPanelView: View {
    let model: CallRecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRecording {
                CallRecordingView(model: model)
            } else if let notice = model.notice {
                Text(verbatim: notice)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(voiceString("Close")) { model.closePicker() }
                }
            } else {
                CallPickerView(model: model)
            }
        }
        .padding(14)
        .padding(.top, 6)
        .frame(width: 300, alignment: .leading)
    }
}

/// Before the start: which program to record.
private struct CallPickerView: View {
    @Bindable var model: CallRecordingController

    var body: some View {
        voiceText("Record a Call")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
        Picker(selection: $model.choice) {
            ForEach(model.apps) { app in
                Text(verbatim: app.isPlaying ? "\(app.name) ♪" : app.name)
                    .tag(CallSourceChoice.app(app.bundleID))
                    .accessibilityLabel(app.isPlaying ? voiceString("\(app.name), plays sound") : app.name)
            }
            if !model.apps.isEmpty {
                Divider()
            }
            voiceText("Entire System").tag(CallSourceChoice.system)
        } label: {
            voiceText("Source")
        }
        voiceText("Programs that used sound are listed. Pick the one the call is in.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let problem = model.problem {
            Text(verbatim: problem)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(voiceString("Refresh")) { model.refreshApps() }
            Spacer()
            Button(voiceString("Cancel")) { model.closePicker() }
                .keyboardShortcut(.cancelAction)
            Button(voiceString("Start Recording")) { model.start() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// While it records.
private struct CallRecordingView: View {
    let model: CallRecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: CallRecorder.Status { model.status }
    private var paused: Bool { status.phase == .paused }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                level(voiceString("Me"), model.recorder.meters.mic)
                level(voiceString("Others"), model.recorder.meters.sys)
                notice(at: context.date)
                    .frame(minHeight: 44, alignment: .topLeading)
                HStack {
                    Spacer()
                    Button(paused ? voiceString("Resume") : voiceString("Pause")) { model.togglePause() }
                    Button(voiceString("Stop")) { model.stop() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(paused ? Color.secondary : Color.red)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            let elapsed = status.elapsed(at: mach_absolute_time())
            Text(verbatim: callClock(elapsed))
                .font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                .accessibilityLabel(paused ? voiceString("Paused at \(callClock(elapsed))")
                                           : voiceString("Recording, \(callClock(elapsed))"))
            Text(verbatim: sourceName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }

    private var sourceName: String {
        switch status.source {
        case let .app(_, name): name
        case .system, nil: voiceString("Entire System")
        }
    }

    private func level(_ title: String, _ value: Float) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title)
                .font(.caption)
                .frame(width: 86, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(paused ? 0 : sqrt(value)))
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: value)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value > 0.01 ? voiceString("Sound") : voiceString("Silence"))
    }

    /// One line at a time, the most pressing first.
    @ViewBuilder private func notice(at now: Date) -> some View {
        switch status.systemAudio {
        case .notPermitted, .silent:
            VStack(alignment: .leading, spacing: 6) {
                voiceText("The system audio is not recorded. Open System Settings → Privacy & Security → System Audio Recording and turn Perekey on.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(voiceString("Open System Settings")) { model.openPrivacySettings() }
            }
        case .waitingForPermission:
            voiceText("macOS asks to allow recording the system audio: answer in its window.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            voiceText("The system audio is not recorded: the device did not start. The microphone goes on.")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .starting, .running:
            if let changed = model.deviceChangedAt, now.timeIntervalSince(changed) < 6 {
                voiceText("The device changed. The recording goes on.")
                    .font(.callout)
            } else if model.outputIsSpeakers {
                voiceText("Put on headphones: from the speakers the others also reach your microphone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
