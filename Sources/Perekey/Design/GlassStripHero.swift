// SPDX-License-Identifier: GPL-3.0-or-later

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

    private func smooth(_ t: Double, from start: Double, length: Double) -> Double {
        let x = min(max((t - start) / length, 0), 1)
        return 1 - pow(1 - x, 3)
    }

    private func frame(at t: Double) -> some View {
        // cover 1.0-1.95, swap at 1.9-2.1, peel 3.0-3.95
        let cover = smooth(t, from: 1.0, length: 0.95)
        let peel = smooth(t, from: 3.0, length: 0.95)
        let swapped = t >= 2.0
        let swapping = abs(t - 2.0) < 0.12
        let fixed = t >= 3.95
        let faded = t > 5.5 ? 1 - min((t - 5.5) / 0.5, 1) : 1
        return ZStack(alignment: .leading) {
            Text(verbatim: swapped ? "привет" : "ghbdtn")
                .font(PK.Font.heroWord)
                .tracking(-2.1)
                .foregroundStyle(Color.pkInk)
                .blur(radius: swapping ? 6 : 0)
                .opacity(swapping ? 0.4 : 1)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.pkIndigo.opacity(0.5))
                        .frame(height: 1.5)
                        .offset(y: 4)
                        .opacity(fixed ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            GeometryReader { proxy in
                let width = proxy.size.width
                let left = width * peel
                let right = width * cover
                Color.clear
                    .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.row, style: .continuous))
                    .frame(width: max(right - left, 0))
                    .offset(x: left)
                    .opacity(right - left > 1 ? 1 : 0)
            }
        }
        .fixedSize()
        .opacity(faded)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: "ghbdtn → привет"))
    }
}
