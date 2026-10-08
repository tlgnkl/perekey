// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import SwiftUI

/// What the capsule shows. A plain value so it renders the same in the menu bar,
/// in the menu header and in debug snapshots.
struct CapsuleModel: Equatable {
    var code: String
    /// Automatic switching is off: the code is struck through.
    var struck = false
    var reason: PauseReason?
    var now = Date()
}

/// The signature capsule: the layout code in Indigo Ink on a glass strip with a
/// 1pt ring; a pause reason adds its glyph and text before the code, and the
/// hatch ("not counted") lies over the strip while Perekey is held.
/// Colors come from `dark`, not from the environment, so a snapshot can draw
/// either look without a window of that appearance.
///
/// `animated` is for live views (the menu bar, the menu header). Then:
/// - a layout change slides the label up out and the new one in from below, and a sheen crosses;
/// - a pause wipes the hatch over the strip and slides the reason in with a width spring;
/// - `pressed` scales to .94, `open` adds the Indigo Mist halo;
/// - each change of `flash` makes the strip glow for 0.6 s (a correction happened).
/// Nothing runs while nothing changes. Under Reduce Motion every movement is
/// a change of opacity.
struct CapsuleView: View {
    let model: CapsuleModel
    let dark: Bool
    var height: CGFloat = 20
    var fontSize: CGFloat = 11.5
    var animated = false
    var pressed = false
    var open = false
    var flash = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var held: Bool { model.reason != nil }
    private var ink: Color {
        held ? PK.inkPair.resolved(dark: dark) : PK.indigoInkPair.resolved(dark: dark)
    }
    private var ring: Color {
        PK.indigoPair.resolved(dark: dark).opacity(contrast == .increased ? 0.9 : (dark ? 0.55 : 0.35))
    }

    /// The animation, or a short fade under Reduce Motion.
    private func motion(_ full: Animation) -> Animation? {
        guard animated else { return nil }
        return reduceMotion ? .easeOut(duration: 0.15) : full
    }

    var body: some View {
        let glowPad = height * 0.1
        HStack(spacing: 4) {
            if let reason = model.reason {
                reasonLabel(reason)
                    .transition(reduceMotion ? .opacity : .modifier(active: ReasonSlide(active: true), identity: ReasonSlide(active: false)))
                Rectangle().fill(ring).frame(width: 1, height: height * 0.45)
                    .transition(.opacity)
            }
            codeLabel
        }
        .foregroundStyle(ink)
        .padding(.horizontal, height * 0.4)
        .frame(minWidth: height * 2.3, minHeight: height, maxHeight: height)
        // The reason slides in from behind the code, not over the neighbours.
        .clipShape(Capsule())
        .background {
            ZStack {
                StripFill(shape: Capsule(), dark: dark, glowRadius: height * 0.15, glowOffset: height * 0.08)
                hatch
            }
        }
        .overlay(Capsule().strokeBorder(ring, lineWidth: 1))
        .overlay { if animated && !reduceMotion { Sheen(trigger: model.code, dark: dark).clipShape(Capsule()) } }
        .overlay { if animated { Flash(trigger: flash, dark: dark, height: height) } }
        .overlay {
            if open {
                Capsule().strokeBorder(PK.mistPair.resolved(dark: dark), lineWidth: 3).padding(-1.5)
                    .transition(.opacity)
            }
        }
        .animation(motion(.timingCurve(0.2, 1.2, 0.3, 1, duration: 0.55)), value: model.reason)
        .animation(motion(.easeOut(duration: 0.2)), value: open)
        .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
        .animation(motion(PK.Motion.spring), value: pressed)
        .padding(glowPad)
        .fixedSize()
    }

    private func reasonLabel(_ reason: PauseReason) -> some View {
        let text = reason.capsuleText(now: model.now)
        return HStack(spacing: 4) {
            Image(systemName: reason.symbol)
                .font(.system(size: fontSize - 1.5, weight: .bold))
            Text(text)
                .font(.system(size: fontSize - 1.5, weight: .semibold))
                .lineLimit(1)
                // A changed text ticks in from below.
                .id(text)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
        .animation(motion(PK.Motion.settle(0.38)), value: text)
    }

    /// The hatch wipes over the strip left to right (.6 s) when Perekey is held.
    @ViewBuilder private var hatch: some View {
        let shown = held ? 1.0 : 0.0
        let wipe = animated && !reduceMotion
        Hatch(color: PK.inkPair.resolved(dark: dark).opacity(0.11), on: 3, off: 4)
            .clipShape(Capsule())
            .opacity(wipe ? 1 : shown)
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle().frame(width: wipe ? proxy.size.width * shown : proxy.size.width)
                }
            }
            .animation(motion(PK.Motion.easeOut(0.6)), value: held)
    }

    @ViewBuilder private var codeLabel: some View {
        let label = Text(model.code)
            .font(.system(size: fontSize, weight: .heavy))
            .tracking(0.06 * fontSize)
            .strikethrough(model.struck, color: ink)
            .opacity(model.struck ? 0.7 : 1)
        if animated {
            label
                .id(model.code)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .frame(height: height)
                .clipped()
                .animation(motion(PK.Motion.settle(0.55)), value: model.code)
        } else {
            label
        }
    }
}

/// The reason enters from the code side: offset, blur 3pt and no opacity at first.
private struct ReasonSlide: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: active ? 12 : 0)
            .blur(radius: active ? 3 : 0)
            .opacity(active ? 0 : 1)
    }
}

/// A white band that crosses the strip once each time `trigger` changes.
private struct Sheen<T: Equatable & Sendable>: View {
    let trigger: T
    let dark: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Color.clear.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { _, phase in
                LinearGradient(colors: [.clear, .white.opacity(dark ? 0.35 : 0.8), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width * 0.5)
                    .offset(x: -width * 0.5 + phase * width * 1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(phase >= 1 ? 0 : 1)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.001)
                    CubicKeyframe(1, duration: 0.85)
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
    }
}

/// An Indigo glow that rises and fades in 0.6 s each time `trigger` changes:
/// "Perekey just fixed a word", for when the hint is off screen. Only opacity
/// moves, so Reduce Motion needs no other variant. The glow stays inside the capsule's
/// padding, because a menu bar view cannot draw outside its item.
private struct Flash: View {
    let trigger: Int
    let dark: Bool
    let height: CGFloat

    var body: some View {
        Color.clear.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { _, level in
            ZStack {
                Capsule().fill(PK.indigoPair.resolved(dark: dark).opacity(0.28))
                Capsule().strokeBorder(PK.indigoPair.resolved(dark: dark), lineWidth: 2)
                    .blur(radius: 1.5)
            }
            .padding(-height * 0.05)
            .opacity(level)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: 0.12)
                CubicKeyframe(0, duration: 0.48)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
