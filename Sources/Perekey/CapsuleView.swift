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
/// Colors come from `dark`, not from the environment, because the image for the
/// menu bar is rendered outside any view hierarchy.
///
/// `animated` is for live views (the menu header): the label slides in from
/// below and a sheen crosses when the layout changes. The menu bar image is
/// static, so it cannot play either.
struct CapsuleView: View {
    let model: CapsuleModel
    let dark: Bool
    var height: CGFloat = 20
    var fontSize: CGFloat = 11.5
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var held: Bool { model.reason != nil }
    private var ink: Color {
        held ? PK.inkPair.resolved(dark: dark) : PK.indigoInkPair.resolved(dark: dark)
    }
    private var ring: Color {
        PK.indigoPair.resolved(dark: dark).opacity(contrast == .increased ? 0.9 : (dark ? 0.55 : 0.35))
    }

    var body: some View {
        let glowPad = height * 0.1
        HStack(spacing: 4) {
            if let reason = model.reason {
                Image(systemName: reason.symbol)
                    .font(.system(size: fontSize - 1.5, weight: .bold))
                Text(reason.capsuleText(now: model.now))
                    .font(.system(size: fontSize - 1.5, weight: .semibold))
                    .lineLimit(1)
                Rectangle().fill(ring).frame(width: 1, height: height * 0.45)
            }
            codeLabel
        }
        .foregroundStyle(ink)
        .padding(.horizontal, height * 0.4)
        .frame(minWidth: height * 2.3, minHeight: height, maxHeight: height)
        .background {
            ZStack {
                StripFill(shape: Capsule(), dark: dark, glowRadius: height * 0.15, glowOffset: height * 0.08)
                if held {
                    Hatch(color: PK.inkPair.resolved(dark: dark).opacity(0.11), on: 3, off: 4)
                        .clipShape(Capsule())
                }
            }
        }
        .overlay(Capsule().strokeBorder(ring, lineWidth: 1))
        .overlay { if animated && !reduceMotion { Sheen(trigger: model.code, dark: dark).clipShape(Capsule()) } }
        .padding(glowPad)
        .fixedSize()
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
                .pkAnimation(PK.Motion.settle(0.55), value: model.code)
        } else {
            label
        }
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
        .allowsHitTesting(false)
    }
}

/// The menu bar label.
///
/// `MenuBarExtra` labels render only `Text` and `Image`, so the capsule is drawn
/// into an `NSImage` with `ImageRenderer` (scale 2, not a template so the ring
/// keeps its color). An `NSStatusItem` would allow live views, but it also means
/// driving the popover by hand, and the label already redraws when the observed
/// layout, settings or pause state change. The ink follows the color scheme of
/// the label's environment; the menu bar tint can differ from it on exotic
/// wallpapers, which is the price of a static image.
struct CapsuleLabel: View {
    let model: CapsuleModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: CapsuleImage.make(model, dark: colorScheme == .dark))
    }
}

enum CapsuleImage {
    @MainActor
    static func make(_ model: CapsuleModel, dark: Bool) -> NSImage {
        let renderer = ImageRenderer(content: CapsuleView(model: model, dark: dark))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = false
        return image
    }
}
