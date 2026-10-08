// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import SwiftUI

/// The first-run window: what Perekey does, Accessibility, shortcuts, a try-out.
struct OnboardingView: View {
    let model: OnboardingModel
    var finish: () -> Void = {}
    /// Freezes the hero animation at a moment in its 6s loop (snapshots); `nil` plays it.
    var heroPhase: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            progress
            ZStack(alignment: .topLeading) {
                Group {
                    switch model.step {
                    case .welcome: WelcomeStep(heroPhase: heroPhase)
                    case .access: AccessStep(model: model)
                    case .preset: PresetStep(model: model)
                    case .demo: DemoStep(model: model)
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.step)
                .transition(StepSlide(direction: CGFloat(model.direction), reduced: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? .easeOut(duration: 0.2) : PK.Motion.easeOut(0.42), value: model.step)
            footer
        }
        .frame(width: 640, height: 580)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                let current = step == model.step
                Capsule()
                    .fill(step.rawValue < model.step.rawValue ? Color.pkIndigo.opacity(0.55) : Color.pkWashDeep)
                    .overlay { if current { Color.clear.glassStrip(in: Capsule(), glow: false) } }
                    .frame(width: current ? 34 : 8, height: 8)
            }
        }
        .pkAnimation(PK.Motion.spring, value: model.step)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .accessibilityElement()
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .buttonStyle(.pkSecondary)
            }
            Spacer()
            if model.step == .access, !model.trusted {
                Text("Allow access first").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            }
            if model.step == .demo {
                Button("Done") { finish() }
                    .buttonStyle(.pkPrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.next() }
                    .buttonStyle(.pkPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canGoForward)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// A step slides 40pt and blurs in from the side the user is heading to, and
/// the old one leaves the other way. Reduce Motion: a fade.
private struct StepSlide: Transition {
    let direction: CGFloat
    let reduced: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let x: CGFloat = switch phase {
        case .willAppear: direction * 40
        case .identity: 0
        case .didDisappear: -direction * 40
        }
        content
            .offset(x: reduced ? 0 : x)
            .blur(radius: reduced || phase.isIdentity ? 0 : 6)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let title: LocalizedStringKey
    let lead: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PK.Font.largeTitle).tracking(-0.5).foregroundStyle(Color.pkInk)
                .fixedSize(horizontal: false, vertical: true)
            if let lead {
                Text(lead).font(PK.Font.callout).foregroundStyle(Color.pkInk2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 16)
    }
}

private struct WelcomeStep: View {
    var heroPhase: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GlassStripHero(phase: heroPhase)
                .padding(.top, 14)
                .padding(.bottom, 6)
            StepHeader(title: "Typed in the wrong layout? Perekey fixes it.",
                       lead: "Press a shortcut and Perekey retypes the last word in the other layout. Press it again and the word comes back as it was.")
            HStack(alignment: .top, spacing: 10) {
                Fact(symbol: "keyboard.fill", title: "On your command",
                     text: "A shortcut retypes the last word or the selection. The same shortcut brings it back.")
                Fact(symbol: "sparkles", title: "By itself",
                     text: "After a space Perekey fixes a word typed in the wrong layout. Backspace undoes it.")
                Fact(symbol: "lock.fill", title: "Private",
                     text: "Nothing you type is sent anywhere. The code is open under GPL-3.0.")
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Typed text stays in memory and is never written to disk. Only the lists you see in Settings → Words are saved, on this Mac.")
                .font(PK.Font.caption)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A short statement with a tile: one of three on the welcome step.
private struct Fact: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.pkIndigoInk)
                .frame(width: 26, height: 26)
                .background(Color.pkMist, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
            Text(text).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .pkCard()
    }
}

private struct AccessStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Let Perekey see the keys",
                       lead: "Perekey needs Accessibility access to notice your shortcut and to type the corrected word.")
            HStack(spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1), Color(red: 0.12, green: 0.40, blue: 0.85)], startPoint: .top, endPoint: .bottom)))
                Text("Accessibility").font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
                Spacer()
                pill
            }
            .padding(12)
            .pkCard()

            VStack(spacing: 8) {
                ActionCard(number: 1, title: "Open the list", text: "System Settings opens at Accessibility.") {
                    Button("Open System Settings") { model.requestAccess() }
                        .buttonStyle(.pkPrimary)
                }
                ActionCard(number: 2, title: "Switch Perekey on", text: "If it is missing, drag the icon into the list.") {
                    DraggableAppIcon()
                }
            }
            .padding(.top, 12)

            Group {
                if model.access == .denied {
                    Text("Perekey is still off in the list. Switch it on; this window notices by itself.")
                        .foregroundStyle(Color.pkWarn)
                } else {
                    Text("This window notices the change by itself.")
                        .foregroundStyle(Color.pkInk2)
                }
            }
            .font(PK.Font.caption)
            .padding(.top, 10)
            .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 7) {
                Promise(symbol: "eye.slash.fill", text: "Perekey reads keys only to find the end of a word and to see your shortcuts.")
                Promise(symbol: "memorychip.fill", text: "The current word stays in memory. It is never saved or sent.")
                Promise(symbol: "lock.fill", text: "Password fields are left alone.")
            }
            .padding(.top, 14)
            .padding(.leading, 4)

            Spacer(minLength: 0)
            PKCallout(Text("Start Perekey with “open Perekey.app”, not by running the binary. Otherwise macOS gives the access to Terminal."),
                      symbol: "info.circle", quiet: true)
                .padding(.horizontal, -PK.Space.lg)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var pill: some View {
        switch model.access {
        case .granted: PKStatusPill(kind: .granted, text: Text("Access granted"))
        case .denied: PKStatusPill(kind: .denied, text: Text("Not allowed yet"))
        case .waiting: PKStatusPill(kind: .waiting, text: Text("Waiting for access…"))
        }
    }
}

/// A numbered action: the badge, what to do and the control for it.
private struct ActionCard<Control: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(number)")
                .font(PK.Font.captionStrong)
                .foregroundStyle(Color.pkIndigoInk)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.pkMist))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
                Text(text).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .pkCard()
    }
}

/// One line of what Perekey does with the access.
private struct Promise: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
        } icon: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.pkIndigoInk)
                .frame(width: 16)
        }
    }
}

/// The app icon as a drag source: dropping it on the Accessibility list adds Perekey.
private struct DraggableAppIcon: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Drag me").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 36, height: 36)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
        }
        .help("Drag Perekey into the Accessibility list in System Settings")
    }
}

private struct PresetStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "How do you switch layouts now?",
                       lead: "Pick what you are used to and Perekey follows. You can change it later in Settings.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                    PresetChip(title: preset.title, note: preset.note,
                               isSelected: !model.capsLockChosen && model.store.settings.preset == preset) {
                        model.choose(preset)
                    }
                }
                PresetChip(title: String(localized: "Caps Lock"),
                           note: model.capsLockBlocked ? String(localized: "Already remapped. Use Settings.") : String(localized: "Instant switch; Option retypes"),
                           isSelected: model.capsLockChosen) {
                    model.chooseCapsLock()
                }
                .disabled(model.capsLockBlocked)
                .opacity(model.capsLockBlocked ? 0.5 : 1)
            }
            if model.store.capsLockFailed {
                PKCallout(Text("macOS refused to change Caps Lock."), symbol: "xmark.octagon.fill", tone: .error)
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous))
                    .padding(.top, 12)
            }
            shortcuts
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
    }

    /// What the choice gives: each shortcut with its keys.
    private var shortcuts: some View {
        PKGroup(header: Text("Your shortcuts")) {
            let rows = model.shortcutRows
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { PKDivider() }
                HStack(spacing: 4) {
                    Text(verbatim: row.name).font(PK.Font.body).foregroundStyle(Color.pkInk)
                    Spacer(minLength: 8)
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in PKKeycap(text: key) }
                }
                .padding(.horizontal, PK.Space.lg)
                .padding(.vertical, 6)
                .frame(minHeight: 38)
            }
        }
    }
}

private struct DemoStep: View {
    let model: OnboardingModel
    private let focus = FocusState<OnboardingModel.DemoField?>()
    private static let backspaceKey = "⌫"
    /// The strip that sweeps a demo field when its word is fixed or undone.
    private let shortcutState = State(initialValue: GlassStripPlayer(progress: 1))
    private let autoState = State(initialValue: GlassStripPlayer(progress: 1))
    private var shortcutStrip: GlassStripPlayer { shortcutState.wrappedValue }
    private var autoStrip: GlassStripPlayer { autoState.wrappedValue }

    /// Whether a demo field holds the fixed word, the typed one, or neither.
    private enum Word { case fixed, typed, other }

    private func word(in text: String) -> Word {
        if text.hasPrefix("привет") { return .fixed }
        if text.hasPrefix("ghbdtn") { return .typed }
        return .other
    }

    private func sweep(_ player: GlassStripPlayer, from old: String, to new: String) {
        switch (word(in: old), word(in: new)) {
        case (.typed, .fixed): player.play(.fix)
        case (.fixed, .typed): player.play(.undo)
        default: break
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(title: "Try it yourself", lead: nil)
            exercise(number: 1) {
                HStack(spacing: 6) {
                    Text("Type")
                    Text(verbatim: "ghbdtn").font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text("and press")
                    if let trigger = model.retypeTrigger {
                        ForEach(Array(TriggerText.keycaps(of: trigger).enumerated()), id: \.offset) { _, cap in
                            PKKeycap(text: cap)
                        }
                    } else {
                        Text("your retype shortcut")
                    }
                }
            } field: {
                TextField("Click here and type", text: Bindable(model).demoText)
                    .focused(focus.projectedValue, equals: .shortcut)
                    .pkField(font: .system(size: 20), height: 40)
                    .overlay { solvedRing(model.demoSolved) }
                    .overlay { GlassStripSweep(progress: shortcutStrip.progress, style: shortcutStrip.style) }
                    .onChange(of: model.demoText) { old, new in sweep(shortcutStrip, from: old, to: new) }
            } checks: {
                Check(done: model.didRetype, text: "The shortcut turned ghbdtn into привет")
                Check(done: model.didUndo, text: "The same shortcut brought ghbdtn back")
            }
            exercise(number: 2) {
                HStack(spacing: 6) {
                    Text("Type")
                    Text(verbatim: "ghbdtn").font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text("and press")
                    PKKeycap(text: TriggerText.keyName(KeyCode.space))
                    Text("then")
                    PKKeycap(text: Self.backspaceKey)
                }
            } field: {
                TextField("Click here and type", text: Bindable(model).autoText)
                    .focused(focus.projectedValue, equals: .auto)
                    .pkField(font: .system(size: 20), height: 40)
                    .overlay { solvedRing(model.didAutoSwitch && model.didAutoUndo) }
                    .overlay { GlassStripSweep(progress: autoStrip.progress, style: autoStrip.style) }
                    .onChange(of: model.autoText) { old, new in sweep(autoStrip, from: old, to: new) }
                    .disabled(model.autoSwitchOff)
                    .opacity(model.autoSwitchOff ? 0.5 : 1)
            } checks: {
                Check(done: model.didAutoSwitch, text: "ghbdtn became привет by itself")
                Check(done: model.didAutoUndo, text: "Backspace brought ghbdtn back")
            }
            if model.needsSecondLayout {
                PKCallout(Text("Perekey needs two keyboard layouts, for example English and Russian. Add one in System Settings → Keyboard."))
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous))
            } else if model.autoSwitchOff {
                PKCallout(Text("Automatic switching is off. Turn it on in the menu to try the second exercise."),
                          symbol: "info.circle", quiet: true)
                    .padding(.horizontal, -PK.Space.lg)
            }
            Spacer(minLength: 0)
            whereNext
        }
        .onChange(of: focus.wrappedValue) { _, field in
            if let field { model.activeField = field }
        }
        .onAppear { DispatchQueue.main.async { focus.wrappedValue = .shortcut } }
    }

    /// Where Perekey lives once the window closes.
    private var whereNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            nextRow(symbol: "menubar.rectangle", title: "In the menu bar", text: "Pause, the mode of the current app and the latest fixes.")
            PKDivider()
            nextRow(symbol: "gearshape.fill", title: "In Settings", text: "Shortcuts, apps, sites and words.")
        }
        .pkCard()
        .padding(.bottom, 4)
    }

    private func nextRow(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.pkIndigoInk)
                .frame(width: 26, height: 26)
                .background(Color.pkMist, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
            Text(text).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private func solvedRing(_ solved: Bool) -> some View {
        RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous)
            .strokeBorder(solved ? Color.pkIndigo : .clear, lineWidth: 2)
    }

    private func exercise(number: Int, @ViewBuilder instruction: () -> some View, @ViewBuilder field: () -> some View,
                          @ViewBuilder checks: () -> some View) -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(PK.Font.captionStrong)
                .foregroundStyle(Color.pkIndigoInk)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.pkMist))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                instruction()
                    .font(PK.Font.body)
                    .foregroundStyle(Color.pkInk)
                    .frame(minHeight: 24, alignment: .leading)
                field()
                VStack(alignment: .leading, spacing: 6) { checks() }
                    .padding(.top, 2)
            }
        }
    }
}

private struct Check: View {
    let done: Bool
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text).font(PK.Font.body).foregroundStyle(done ? Color.pkInk : Color.pkInk2)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.pkIndigo : Color.pkInk3)
        }
    }
}
