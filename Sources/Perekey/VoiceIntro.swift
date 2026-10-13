// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import ApplicationServices
import Observation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// The offer of voice input to a person who has not turned it on: what the
/// window "What's new: voice input" and the voice step of the first-run window
/// show and do. Without an answer voice stays off and no shortcut changes.
@MainActor
@Observable
final class VoiceIntroModel {
    let settings: VoiceSettingsStore
    let models: VoiceModelsController
    let store: SettingsStore
    let recording: ShortcutRecording
    /// The key the person picked for voice; the right ⌥ unless they chose another.
    private(set) var trigger: VoiceTrigger = .default
    /// The recorder is shown: the person is picking another key.
    var isPickingKey = false
    /// Settings → Voice, at the list of models.
    @ObservationIgnored var openModels: () -> Void = {}

    init(settings: VoiceSettingsStore, models: VoiceModelsController, store: SettingsStore, recording: ShortcutRecording) {
        self.settings = settings
        self.models = models
        self.store = store
        self.recording = recording
    }

    func choose(_ trigger: VoiceTrigger) {
        self.trigger = trigger
    }

    /// Retype stays on both Option keys: voice is on another key.
    var keepsRetype: Bool { trigger.narrowing(store.settings.hotkeys) == store.settings.hotkeys }

    var conflicts: [ShortcutConflict] {
        ShortcutConflicts.check(voice: trigger, among: store.settings.hotkeys, system: models.systemShortcuts)
    }

    /// Another Perekey shortcut sits on the key: voice must not start there.
    var isTaken: Bool {
        conflicts.contains { if case .otherAction = $0 { true } else { false } }
    }

    /// The default model is not on the disk: the Voice tab is where to get it.
    var needsModel: Bool {
        models.statuses.first { $0.id == settings.settings.model }?.state != .ready
    }

    /// "Turn on voice": on, on the chosen key, and answered. The model is the
    /// person's to download: the Voice tab opens at the list.
    func turnOn() {
        guard !isTaken else { return }
        let trigger = trigger
        settings.update {
            $0.isEnabled = true
            $0.trigger = trigger
            $0.introAnswered = true
        }
        if needsModel { openModels() }
    }

    /// "Not now": voice stays off, and the offer does not come again.
    func notNow() {
        settings.update { $0.introAnswered = true }
    }

    /// The window was closed without a button: the same as "Not now".
    func closed() {
        if !settings.settings.introAnswered { notNow() }
    }
}

// MARK: - Content

/// What both the window and the first-run step say: what voice does, what
/// happens to the shortcuts, which key to use.
struct VoiceIntroContent: View {
    let model: VoiceIntroModel
    /// In the first-run window the voice step is no news.
    var isNews = true

    private var keys: String { TriggerText.keycaps(of: model.trigger.shortcut).joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VoiceIntroHero(caption: caption)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 8) {
                (isNews ? voiceText("What's new: voice input") : voiceText("Voice input"))
                    .font(PK.Font.largeTitle).tracking(-0.5).foregroundStyle(Color.pkInk)
                    .accessibilityAddTraits(.isHeader)
                voiceText("Russian and English in one phrase. The model runs on this Mac, and the sound goes nowhere.")
                    .font(PK.Font.callout).foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                retypeCard
                voiceCard
            }
            .fixedSize(horizontal: false, vertical: true)
            keyChoice
        }
    }

    private var caption: Text {
        switch model.trigger {
        case .tap: voiceText("Tap \(keys), say a phrase, tap again, and the text lands at the cursor")
        case .hold: voiceText("Hold \(keys), say a phrase, let go, and the text lands at the cursor")
        }
    }

    private var retypeCard: some View {
        VoiceIntroCard(tag: model.keepsRetype ? voiceText("ANY") : voiceText("LEFT"),
                       title: voiceText("Retype a word"),
                       detail: model.keepsRetype ? voiceText("On either ⌥, as before") : voiceText("As before"),
                       keycaps: ["⌥"], highlighted: false)
    }

    private var voiceCard: some View {
        VoiceIntroCard(tag: model.trigger == .default ? voiceText("RIGHT · TAP") : voiceText("YOUR KEY"),
                       title: voiceText("Start and end a recording"),
                       detail: model.trigger == .default ? voiceText("It retyped a word too") : nil,
                       keycaps: TriggerText.keycaps(of: model.trigger.shortcut), highlighted: true)
    }

    @ViewBuilder private var keyChoice: some View {
        if model.isPickingKey {
            HStack(spacing: 10) {
                VoiceTriggerButton(trigger: model.trigger, recording: model.recording) { model.choose($0) }
                if model.trigger != .default {
                    Button { model.choose(.default) } label: { voiceText("Right ⌥") }
                        .buttonStyle(.pkLink)
                        .help(voiceText("Back to a tap of the right Option key"))
                }
            }
            ForEach(model.conflicts, id: \.self) { conflict in
                PKCallout(Text(verbatim: TriggerText.warning(for: conflict)))
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
            }
            if model.isTaken { voiceText("This key is taken. Pick another one for voice.").font(PK.Font.caption).foregroundStyle(Color.pkWarn) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                voiceText("Retype with the right ⌥? Pick another key for voice, and ⌥ stays as it was.")
                    .font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.isTaken {
                    // The preset puts a language on the right ⌥: voice cannot take it.
                    voiceText("This key is taken. Pick another one for voice.").font(PK.Font.caption).foregroundStyle(Color.pkWarn)
                }
                Button { model.isPickingKey = true } label: { voiceText("Pick another key for voice") }
                    .buttonStyle(.pkLink)
            }
        }
    }
}

/// One of the two cards: which key does what.
private struct VoiceIntroCard: View {
    let tag: Text
    let title: Text
    let detail: Text?
    let keycaps: [String]
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            keycap
            VStack(alignment: .leading, spacing: 2) {
                tag.font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(highlighted ? Color.pkIndigoInk : Color.pkInk3)
                title.font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(highlighted ? Color.pkMist : Color.clear)
        .pkCard(radius: PK.Radius.menu)
        .accessibilityElement(children: .combine)
    }

    private var keycap: some View {
        HStack(spacing: 4) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { _, cap in
                Text(verbatim: cap)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white : Color.pkInk)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 34, minHeight: 34)
                    .background(highlighted ? Color.pkIndigoFill : Color.pkPlate,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A recording as it looks at the caret, over the phrase it will type.
private struct VoiceIntroHero: View {
    let caption: Text
    private static let sample = DictationHUDPresentation(
        message: .recording, buttons: [.cancel], meter: .init(level: 0.55, seconds: 3))

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 6) {
                VoiceHUDContent(presentation: Self.sample)
                    .clipShape(Capsule())
                    .pkGlass(in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.pkRule, lineWidth: 0.5))
                    .allowsHitTesting(false)
                Text(verbatim: "Открой pull request в main")
                    .font(.system(size: 24, weight: .semibold)).tracking(-0.3)
                    .foregroundStyle(Color.pkInk)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 28)
            .background(Color.pkPlate.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
            .accessibilityHidden(true)
            caption.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Window

/// The one window "What's new: voice input", for someone who already uses
/// Perekey. A plain `NSWindow`, as the first-run window is. Closing it is an
/// answer: "Not now".
@MainActor
final class VoiceIntroController: NSObject, NSWindowDelegate {
    private let makeModel: @MainActor () -> VoiceIntroModel
    private let situation: @MainActor () -> VoiceIntro.Situation
    private var window: NSWindow?
    private var model: VoiceIntroModel?

    init(situation: @escaping @MainActor () -> VoiceIntro.Situation, makeModel: @escaping @MainActor () -> VoiceIntroModel) {
        self.situation = situation
        self.makeModel = makeModel
    }

    /// Shows the window when the person is offered voice and has not answered.
    func showIfNeeded() {
        guard window == nil, VoiceIntro.offer(situation()) == .window else { return }
        let model = makeModel()
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = voiceString("What's new: voice input")
        window.contentView = NSHostingView(rootView: VoiceIntroView(model: model) { [weak self] in self?.window?.close() })
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model?.closed()
        model?.recording.stop()
        model = nil
        window = nil
    }
}

struct VoiceIntroView: View {
    let model: VoiceIntroModel
    var finish: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            VoiceIntroContent(model: model)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button { model.notNow(); finish() } label: { voiceText("Not now") }
                    .buttonStyle(.pkSecondary)
                Spacer()
                Button { model.turnOn(); finish() } label: { voiceText("Turn on voice") }
                    .buttonStyle(.pkPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isTaken)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 580)
    }
}
#endif
