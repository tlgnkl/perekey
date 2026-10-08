// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import SwiftUI

/// The first-run window: what Perekey does, Accessibility, shortcuts, a try-out.
struct OnboardingView: View {
    let model: OnboardingModel
    var finish: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            progress
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
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
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 34, height: 6)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
        .accessibilityElement()
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }
            }
            Spacer()
            if model.step == .access, !model.trusted {
                Text("Allow access first").font(.callout).foregroundStyle(.secondary)
            }
            if model.step == .demo {
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.next() }
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
            Text(title).font(.title.weight(.semibold))
            if let lead {
                Text(lead).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 16)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(verbatim: "ghbdtn").foregroundStyle(.secondary).strikethrough()
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                Text(verbatim: "привет").fontWeight(.semibold)
            }
            .font(.system(size: 30, design: .rounded))
            .padding(.top, 20)
            StepHeader(title: "Typed in the wrong layout? Perekey fixes it.",
                       lead: "Press a shortcut and Perekey retypes the last word in the other layout. Press it again and the word comes back as it was.")
            Text("Perekey remembers only the last word, and only in memory. It never sends what you type anywhere. The code is open under GPL-3.0, so you can check.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .font(.title2)
                    .frame(width: 36)
                Text("Accessibility").fontWeight(.semibold)
                Spacer()
                pill
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Text("1. Click “Open System Settings”.")
                Text("2. Switch Perekey on in the Accessibility list. If it is missing, drag the icon below into the list.")
                Text("This window notices the change by itself.").foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            HStack(spacing: 16) {
                Button("Open System Settings") { model.requestAccess() }
                    .buttonStyle(.borderedProminent)
                DraggableAppIcon()
            }
            .padding(.top, 16)

            Label("Start Perekey with “open Perekey.app”, not by running the binary. Otherwise macOS gives the access to Terminal.",
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
        }
    }

    @ViewBuilder private var pill: some View {
        if model.trusted {
            Label("Access granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for access…").foregroundStyle(.secondary)
            }
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
            Text("Drag me into the list").font(.callout).foregroundStyle(.secondary)
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
                Label("macOS refused to change Caps Lock.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
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
                Text(verbatim: "ghbdtn").font(.body.monospaced().bold())
                Text("and press")
                if let trigger = model.retypeTrigger {
                    ForEach(Array(TriggerText.keycaps(of: trigger).enumerated()), id: \.offset) { _, cap in
                        Keycap(text: cap)
                    }
                } else {
                    Text("your retype shortcut")
                }
            }
            .padding(.bottom, 12)

            TextField("Click here and type", text: Binding(get: { model.demoText }, set: { model.demoText = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(model.demoSolved ? AnyShapeStyle(.green) : AnyShapeStyle(.clear), lineWidth: 2)
                }

            if model.needsSecondLayout {
                Label("Perekey needs two keyboard layouts, for example English and Russian. Add one in System Settings → Keyboard.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
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
            Text(text).foregroundStyle(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        }
    }
}
