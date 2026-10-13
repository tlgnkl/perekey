// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyVoice
import SwiftUI

/// What the HUD view draws. The controller changes `visible` inside
/// `withAnimation`, so the enter and the exit run as DESIGN.md says.
@MainActor @Observable
final class VoiceHUDModel {
    var presentation: DictationHUDPresentation
    var visible: Bool
    /// Frames of the buttons in the hosting view, top-left origin; the panel
    /// takes mouse events there and nowhere else.
    var buttonFrames: [CGRect] = []
    @ObservationIgnored var onButtonFramesChange: (() -> Void)?

    init(_ presentation: DictationHUDPresentation, visible: Bool = false) {
        self.presentation = presentation
        self.visible = visible
    }
}

private struct HUDButtonFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Room around the capsule for its shadow; the panel is this much larger.
enum VoiceHUDMetrics {
    static let shadowInset: CGFloat = 18
}

/// The capsule at its natural size. `VoiceHUDView` adds the shadow room and the
/// glass; the controller measures a copy of this to size the panel.
struct VoiceHUDContent: View {
    let presentation: DictationHUDPresentation
    var perform: (DictationHUDPresentation.Button) -> Void = { _ in }
    /// Snapshots: draw the Reduce Motion and Increase Contrast looks.
    var calmOverride = false
    var contrastOverride = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorContrast

    private var calm: Bool { calmOverride || reduceMotion }

    var body: some View {
        HStack(spacing: 10) {
            if let meter = presentation.meter {
                meterView(meter)
            }
            if presentation.meter == nil || presentation.message == .preparingModel {
                lead
                Text(verbatim: presentation.message.text)
                    .font(.system(size: 12.5, weight: presentation.message.isProblem ? .semibold : .medium))
                    .foregroundStyle(presentation.message.isProblem ? Color.pkInk : Color.pkInk)
                    .lineLimit(1)
            }
            if let mode = presentation.modeName, !mode.isEmpty {
                modeTag(mode)
            }
            if !presentation.buttons.isEmpty {
                Rectangle().fill(Color.pkRule).frame(width: 1, height: 14).accessibilityHidden(true)
                ForEach(presentation.buttons, id: \.self) { button in
                    chip(button)
                }
            }
        }
        .fixedSize()
        .padding(.leading, 13)
        .padding(.trailing, presentation.buttons.isEmpty ? 14 : 6)
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    /// The glyph, or a spinner while the HUD waits.
    @ViewBuilder private var lead: some View {
        if let symbol = presentation.message.symbol {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } else if presentation.meter == nil {
            Spinner(calm: calm).accessibilityHidden(true)
        }
    }

    private var tint: Color {
        switch presentation.message {
        case .pasted, .copied: Color.pkOK
        case .cancelled: Color.pkInk2
        case .secureField, .secureInput: Color.pkInk2
        default: Color.pkWarn
        }
    }

    /// The mode, ☁ when the audio or the text leaves the Mac, and the
    /// language model's server while it works.
    private func modeTag(_ mode: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: mode)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            if presentation.cloud || presentation.endpointName != nil {
                HStack(spacing: 3) {
                    if presentation.cloud { Image(systemName: "cloud").font(.system(size: 10, weight: .semibold)) }
                    if let endpoint = presentation.endpointName { Text(verbatim: endpoint) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.pkInk2)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func meterView(_ meter: DictationHUDPresentation.Meter) -> some View {
        HStack(spacing: 8) {
            if calm {
                // Reduce Motion: a steady dot, the timer shows that it runs.
                Circle().fill(Color.pkRose).frame(width: 8, height: 8)
            } else {
                LevelBars(level: CGFloat(meter.level))
            }
            Text(verbatim: meter.timerText)
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.pkInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DictationHUDPresentation.Message.recording.text))
        .accessibilityValue(Text(verbatim: meter.timerText))
    }

    private func chip(_ button: DictationHUDPresentation.Button) -> some View {
        Button { perform(button) } label: {
            HStack(spacing: 5) {
                Text(verbatim: button.title).font(.system(size: 12.5, weight: .semibold))
                if let keycap = button.keycap {
                    Text(verbatim: keycap)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.pkInk)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 22, minHeight: 15)
                        .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(contrast ? Color.pkInk : Color.pkRule, lineWidth: contrast ? 1 : 0.5))
                }
            }
            .foregroundStyle(Color.pkIndigoInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.pkMist))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: button.accessibilityLabel))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HUDButtonFramesKey.self, value: [proxy.frame(in: .named("voice-hud"))])
        })
    }

    private var contrast: Bool { contrastOverride || colorContrast == .increased }
}

/// Five bars that follow the loudness of the voice.
private struct LevelBars: View {
    let level: CGFloat
    private static let profile: [CGFloat] = [0.55, 0.85, 1, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(Self.profile.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(Color.pkIndigo)
                    .frame(width: 3, height: 3 + 11 * min(1, max(0, level * weight)))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// A small arc that turns. Under Reduce Motion it stays an arc.
private struct Spinner: View {
    let calm: Bool
    // `State` as a value: the property wrapper's macro needs Xcode's plugin.
    private let angle = State(initialValue: 0.0)

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.pkIndigo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(angle.wrappedValue))
            .onAppear {
                guard !calm else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle.wrappedValue = 360 }
            }
    }
}

/// The glass capsule at the caret: the same glass, rim and glow as the hint.
struct VoiceHUDView: View {
    let model: VoiceHUDModel
    var perform: (DictationHUDPresentation.Button) -> Void = { _ in }
    /// Snapshots.
    var calmOverride = false
    var contrastOverride = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: Capsule { Capsule() }

    var body: some View {
        let dark = scheme == .dark
        let contrast = contrastOverride || colorContrast == .increased
        VoiceHUDContent(presentation: model.presentation, perform: perform, calmOverride: calmOverride,
                        contrastOverride: contrastOverride)
            .clipShape(shape)
            .pkGlass(in: shape)
            .background(shape.fill(Color.pkPlate.opacity(contrast || reduceTransparency ? 0.96 : (dark ? 0.55 : 0.6))))
            .overlay(shape.strokeBorder(.white.opacity(dark ? 0.16 : 0.7), lineWidth: 0.5))
            .overlay(shape.strokeBorder(contrast ? Color.pkInk : Color.pkRule, lineWidth: contrast ? 1.5 : 0.5))
            .shadow(color: Color.pkGlow, radius: 14, x: 0, y: 8)
            .shadow(color: Color.pkIndigo.opacity(dark ? 0.3 : 0.16), radius: 2, x: 0, y: 1)
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible ? 1 : 0.96, anchor: .center)
            .offset(y: model.visible ? 0 : 4)
            .padding(VoiceHUDMetrics.shadowInset)
            .coordinateSpace(name: "voice-hud")
            .onPreferenceChange(HUDButtonFramesKey.self) {
                model.buttonFrames = $0
                model.onButtonFramesChange?()
            }
    }
}
#endif
