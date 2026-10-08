// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyInput
import SwiftUI

/// Which way a glass strip correction goes. An undo wipes the same strip but
/// glows rose instead of indigo, and the caller swaps `before` and `after`.
enum GlassStripStyle: Equatable {
    case fix
    case undo
}

enum GlassStrip {
    /// Linear over the whole correction: `GlassStripTimeline` shapes the phases
    /// with the DESIGN.md curve. Reduce Motion collapses it to a quick cross-fade.
    static func animation(delay: Double = 0) -> Animation {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return Animation.linear(duration: reduced ? 0.2 : GlassStripTimeline.duration).delay(delay)
    }
}

/// One word under the glass strip correction: cover, retype, peel. Draws
/// `before` at `progress` 0 and `after` at 1; between, the strip wipes in, the
/// old word blurs out and the new one blurs in under it, and the strip peels
/// off. A fixed word (style `.fix`) keeps the indigo underline.
///
/// It is `Animatable`: drive `progress` with `GlassStripPlayer`, or with
/// `withAnimation(GlassStrip.animation()) { progress = 1 }`. Nothing runs
/// while it rests, so an idle view costs no frames. The width follows `after`;
/// `before` overlays it from the left edge.
///
/// ```
/// GlassStripWord(before: "ghbdtn", after: "привет", progress: player.progress,
///                style: player.style, font: .system(size: 13.5))
/// ```
struct GlassStripWord: View, Animatable {
    var before: String
    var after: String
    /// 0 ... 1; see `GlassStripTimeline`.
    var progress: Double
    var style: GlassStripStyle = .fix
    var font: Font = .system(size: 13)
    var color: Color = .pkInk
    /// Color of `before`; `color` when nil.
    var beforeColor: Color?
    /// The fixed-word underline under `after`, once the strip has peeled.
    var underline = true
    /// How far the strip reaches past the text.
    var inset = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
    var radius: CGFloat = 8
    var tracking: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GlassStripFrameWord(before: before, after: after,
                            frame: GlassStripTimeline.frame(at: progress, reducedMotion: reduceMotion),
                            style: style, font: font, color: color, beforeColor: beforeColor, underline: underline,
                            inset: inset, radius: radius, tracking: tracking)
    }
}

/// `GlassStripWord` for a caller with its own clock, such as the onboarding
/// hero's 6 s loop: it draws the `GlassStripTimeline.Frame` it is given.
struct GlassStripFrameWord: View {
    var before: String
    var after: String
    var frame: GlassStripTimeline.Frame
    var style: GlassStripStyle = .fix
    var font: Font = .system(size: 13)
    var color: Color = .pkInk
    var beforeColor: Color?
    var underline = true
    var inset = EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
    var radius: CGFloat = 8
    var tracking: CGFloat = 0

    var body: some View {
        Text(verbatim: after)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(color)
            .opacity(frame.swap)
            .blur(radius: (1 - frame.swap) * 6)
            .overlay(alignment: .leading) {
                Text(verbatim: before)
                    .font(font)
                    .tracking(tracking)
                    .foregroundStyle(beforeColor ?? color)
                    .fixedSize()
                    .opacity(1 - frame.swap)
                    .blur(radius: frame.swap * 6)
            }
            .overlay(alignment: .bottom) {
                if underline, style == .fix {
                    Rectangle().fill(Color.pkIndigo.opacity(0.5)).frame(height: 1.5).offset(y: 4)
                        .opacity(frame.peel)
                }
            }
            .overlay { GlassStripBand(frame: frame, style: style, radius: radius, inset: inset) }
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: frame.swap < 0.5 ? before : after))
    }
}

/// Only the strip: it wipes over whatever it is laid on and peels off. For a
/// field whose text the system changes, such as the onboarding demo; the words
/// are already swapped, so there is nothing to blur. Animatable like
/// `GlassStripWord`.
struct GlassStripSweep: View, Animatable {
    var progress: Double
    var style: GlassStripStyle = .fix
    var radius: CGFloat = PK.Radius.field
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // Reduce Motion has no strip: the field's own text just changes.
        GlassStripBand(frame: GlassStripTimeline.frame(at: progress, reducedMotion: reduceMotion), style: style,
                       radius: radius, inset: EdgeInsets())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The strip itself, between the `peel` and `cover` edges of its container.
struct GlassStripBand: View {
    var frame: GlassStripTimeline.Frame
    var style: GlassStripStyle
    var radius: CGFloat
    var inset: EdgeInsets

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let width = proxy.size.width + inset.leading + inset.trailing
            let left = width * frame.peel
            let right = width * frame.cover
            Color.clear
                .glassStrip(in: shape, glow: style == .fix)
                .background {
                    // The rose under-glow of an undone fix; Rim-and-Glow, never grey.
                    if style == .undo {
                        shape.fill(Color.pkRose.opacity(0.30)).blur(radius: 6).offset(y: 4)
                        shape.strokeBorder(Color.pkRose.opacity(0.35), lineWidth: 1)
                    }
                }
                .frame(width: max(right - left, 0), height: proxy.size.height + inset.top + inset.bottom)
                .offset(x: left - inset.leading, y: -inset.top)
                .opacity(frame.stripVisible ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

/// Plays the correction for a `GlassStripWord`. One player per word; the chip
/// in Settings and the demo field in onboarding each own one.
@MainActor @Observable
final class GlassStripPlayer {
    private(set) var progress: Double
    private(set) var style: GlassStripStyle
    @ObservationIgnored private var run = 0

    /// A resting player: `progress` 0 shows `before`, 1 shows `after`.
    init(progress: Double = 0, style: GlassStripStyle = .fix) {
        self.progress = progress
        self.style = style
    }

    /// Jumps to a state without animating.
    func rest(at progress: Double, style: GlassStripStyle = .fix) {
        run += 1
        self.style = style
        withAnimation(nil) { self.progress = progress }
    }

    /// Plays from `before` to `after`, from the start even when it is running.
    func play(_ style: GlassStripStyle = .fix, delay: Double = 0) {
        run += 1
        let mine = run
        self.style = style
        withAnimation(nil) { progress = 0 }
        // One turn of the run loop, so the reset is drawn before the animation
        // starts from it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.run == mine else { return }
                withAnimation(GlassStrip.animation(delay: delay)) { self.progress = 1 }
            }
        }
    }
}
