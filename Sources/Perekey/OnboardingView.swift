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

    var body: some View {
        VStack(spacing: 0) {
            progress
            Group {
                switch model.step {
                case .welcome: WelcomeStep(heroPhase: heroPhase)
                case .access: AccessStep(model: model)
                case .preset: PresetStep(model: model)
                case .demo: DemoStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
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
            Text("Perekey remembers only the last word, and only in memory. It never sends what you type anywhere. The code is open under GPL-3.0, so you can check.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
        }
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

            VStack(alignment: .leading, spacing: 10) {
                Text("1. Click “Open System Settings”.")
                Text("2. Switch Perekey on in the Accessibility list. If it is missing, drag the icon below into the list.")
                Text("This window notices the change by itself.").foregroundStyle(Color.pkInk2)
            }
            .font(PK.Font.body)
            .foregroundStyle(Color.pkInk)
            .padding(.top, 16)

            HStack(spacing: 16) {
                Button("Open System Settings") { model.requestAccess() }
                    .buttonStyle(.pkPrimary)
                DraggableAppIcon()
            }
            .padding(.top, 16)

            PKCallout(Text("Start Perekey with “open Perekey.app”, not by running the binary. Otherwise macOS gives the access to Terminal."),
                      symbol: "info.circle", quiet: true)
                .padding(.horizontal, -PK.Space.lg)
                .padding(.top, 8)
        }
    }

    @ViewBuilder private var pill: some View {
        if model.trusted {
            PKStatusPill(kind: .granted, text: Text("Access granted"))
        } else {
            PKStatusPill(kind: .waiting, text: Text("Waiting for access…"))
        }
    }
}

/// The app icon as a drag source: dropping it on the Accessibility list adds Perekey.
private struct DraggableAppIcon: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 40, height: 40)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            Text("Drag me into the list").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
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
        }
    }
}

private struct DemoStep: View {
    let model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "Try it yourself", lead: nil)
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
            .font(PK.Font.body)
            .foregroundStyle(Color.pkInk)
            .padding(.bottom, 12)

            TextField("Click here and type", text: Binding(get: { model.demoText }, set: { model.demoText = $0 }))
                .pkField(font: .system(size: 22), height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous)
                        .strokeBorder(model.demoSolved ? Color.pkIndigo : .clear, lineWidth: 2)
                }

            if model.needsSecondLayout {
                PKCallout(Text("Perekey needs two keyboard layouts, for example English and Russian. Add one in System Settings → Keyboard."))
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous))
                    .padding(.top, 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                Check(done: model.didRetype, text: "The shortcut turned ghbdtn into привет")
                Check(done: model.didUndo, text: "The same shortcut brought ghbdtn back")
            }
            .padding(.top, 20)
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
