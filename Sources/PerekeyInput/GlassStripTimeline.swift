// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A CSS-style cubic Bézier easing: `cubic-bezier(x1, y1, x2, y2)`.
public struct CubicBezier: Equatable, Sendable {
    public let x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// The glass strip curve of DESIGN.md.
    public static let strip = CubicBezier(0.3, 0.7, 0.2, 1)

    /// The eased value for time `x` in 0...1.
    public func value(at x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        // Bisect for the curve parameter whose x is `x`; x is monotonic in it.
        var low = 0.0, high = 1.0, t = x
        for _ in 0 ..< 32 {
            t = (low + high) / 2
            if Self.point(t, x1, x2) < x { low = t } else { high = t }
        }
        return Self.point(t, y1, y2)
    }

    private static func point(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }
}

/// The glass strip correction as a function of one number: cover (the strip
/// wipes in left to right), retype (the old word blurs out, the new one blurs
/// in under the strip), peel (the strip wipes out the same way). Pure, so the
/// phases are testable without drawing.
public enum GlassStripTimeline {
    /// Seconds for the whole correction.
    public static let duration: Double = 0.95

    public struct Frame: Equatable, Sendable {
        /// Right edge of the strip, 0...1 of the word's width.
        public var cover: Double
        /// Left edge of the strip, 0...1.
        public var peel: Double
        /// 0 shows the old word, 1 the new one.
        public var swap: Double

        public init(cover: Double, peel: Double, swap: Double) {
            self.cover = cover
            self.peel = peel
            self.swap = swap
        }

        public var stripVisible: Bool { cover - peel > 0.001 }
    }

    // Phases in the share of `duration`; the retype happens while covered.
    static let coverPhase = 0.0 ... 0.42
    static let swapPhase = 0.36 ... 0.62
    static let peelPhase = 0.56 ... 1.0

    /// `progress` runs 0...1 linearly over `duration`. Reduced motion has no
    /// strip: the words cross-fade.
    public static func frame(at progress: Double, reducedMotion: Bool = false) -> Frame {
        let p = min(max(progress, 0), 1)
        if reducedMotion { return Frame(cover: 0, peel: 0, swap: p) }
        return Frame(cover: ease(p, coverPhase), peel: ease(p, peelPhase), swap: ease(p, swapPhase))
    }

    private static func ease(_ p: Double, _ phase: ClosedRange<Double>) -> Double {
        CubicBezier.strip.value(at: (p - phase.lowerBound) / (phase.upperBound - phase.lowerBound))
    }
}
