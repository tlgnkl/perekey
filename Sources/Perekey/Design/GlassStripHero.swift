// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyInput
import SwiftUI

/// The onboarding hero: the glass strip correction on a 6s loop. Cover (the
/// strip wipes in left to right), retype (the old word blurs out and the new
/// one blurs in under the strip), peel (the strip wipes out the same way), rest.
/// Under Reduce Motion it shows the corrected word, still.
struct GlassStripHero: View {
    /// A fixed moment of the loop in seconds (snapshots); `nil` plays it.
    var phase: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let phase {
            frame(at: phase)
        } else if reduceMotion {
            frame(at: 5)
        } else {
            TimelineView(.animation) { context in
                frame(at: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6))
            }
        }
    }

    private func ease(_ t: Double, from start: Double, length: Double) -> Double {
        CubicBezier.strip.value(at: (t - start) / length)
    }

    private func frame(at t: Double) -> some View {
        // cover 1.0-1.95, swap 1.9-2.1, peel 3.0-3.95, the loop's own clock
        let strip = GlassStripTimeline.Frame(cover: ease(t, from: 1.0, length: 0.95),
                                             peel: ease(t, from: 3.0, length: 0.95),
                                             swap: ease(t, from: 1.9, length: 0.2))
        let faded = t > 5.5 ? 1 - min((t - 5.5) / 0.5, 1) : 1
        return GlassStripFrameWord(before: "ghbdtn", after: "привет", frame: strip, font: PK.Font.heroWord,
                                   color: .pkInk, inset: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16),
                                   radius: PK.Radius.row, tracking: -2.1)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .fixedSize()
            .opacity(faded)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "ghbdtn → привет"))
    }
}
