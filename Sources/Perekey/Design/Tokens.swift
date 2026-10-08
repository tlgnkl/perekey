// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Design tokens of «Стеклянная правка» (see DESIGN.md). One place for colors,
/// type, spacing, radii and motion; views never hard-code a hex value.
enum PK {}

/// A light/dark pair. `color` follows the appearance of whatever draws it;
/// `resolved(dark:)` is for the menu bar image, which is drawn outside any view
/// hierarchy and knows its appearance only as a flag.
struct PKPair: Sendable {
    struct RGBA: Sendable {
        var r: Double, g: Double, b: Double, a: Double
        init(_ hex: UInt32, _ alpha: Double = 1) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
            a = alpha
        }
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    }

    let light: RGBA
    let dark: RGBA

    init(_ light: UInt32, _ dark: UInt32, light lightAlpha: Double = 1, dark darkAlpha: Double = 1) {
        self.light = RGBA(light, lightAlpha)
        self.dark = RGBA(dark, darkAlpha)
    }

    func resolved(dark isDark: Bool) -> Color { (isDark ? dark : light).color }

    var color: Color {
        let light = light, dark = dark
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return (isDark ? dark : light).nsColor
        })
    }
}

extension PK {
    // Indigo: the only accent hue.
    static let indigoPair = PKPair(0x5E5CE6, 0x7D7AFF)
    static let indigoFillPair = PKPair(0x5E5CE6, 0x5E5CE6)
    static let indigoInkPair = PKPair(0x4644D0, 0xA9A7FF)
    static let mistPair = PKPair(0x5E5CE6, 0x7D7AFF, light: 0.13, dark: 0.18)
    static let glowPair = PKPair(0x5E5CE6, 0x7D7AFF, light: 0.45, dark: 0.50)
    // Status colors: never decoration.
    static let warnPair = PKPair(0xC26A00, 0xFFB340)
    static let warnSoftPair = PKPair(0xFF9F0A, 0xFF9F0A, light: 0.16, dark: 0.18)
    static let okPair = PKPair(0x1F9D47, 0x32D74B)
    static let okSoftPair = PKPair(0x1F9D47, 0x32D74B, light: 0.16, dark: 0.16)
    static let rosePair = PKPair(0xE0446A, 0xFF6482)
    // Neutrals.
    static let inkPair = PKPair(0x1D1D1F, 0xF5F5F7)
    static let ink2Pair = PKPair(0x66666C, 0xA1A1AA)
    static let ink3Pair = PKPair(0xA1A1A8, 0x6C6C74)
    static let platePair = PKPair(0xFFFFFF, 0x26262C)
    static let rulePair = PKPair(0x000000, 0xFFFFFF, light: 0.08, dark: 0.09)
    static let washPair = PKPair(0x000000, 0xFFFFFF, light: 0.045, dark: 0.06)
    static let washDeepPair = PKPair(0x000000, 0xFFFFFF, light: 0.08, dark: 0.10)
    static let rowPair = PKPair(0xFFFFFF, 0xFFFFFF, light: 0.66, dark: 0.05)
    static let windowGlassPair = PKPair(0xFBFBFD, 0x202026, light: 0.80, dark: 0.80)
}

extension Color {
    /// Correction Indigo: glyph and line accent, focus ring, selected outline.
    static let pkIndigo = PK.indigoPair.color
    /// Solid Indigo Fill: the only fill that carries white text. Same in both modes.
    static let pkIndigoFill = PK.indigoFillPair.color
    /// Indigo Ink: accent text on glass or a tinted fill.
    static let pkIndigoInk = PK.indigoInkPair.color
    /// Indigo Mist: halos, tag and action backgrounds.
    static let pkMist = PK.mistPair.color
    /// Indigo Glow: the soft under-glow beneath strips and thumbs.
    static let pkGlow = PK.glowPair.color
    static let pkWarn = PK.warnPair.color
    static let pkWarnSoft = PK.warnSoftPair.color
    static let pkOK = PK.okPair.color
    static let pkOKSoft = PK.okSoftPair.color
    static let pkRose = PK.rosePair.color
    static let pkInk = PK.inkPair.color
    /// Secondary Ink: descriptions, sublabels.
    static let pkInk2 = PK.ink2Pair.color
    /// Quiet Ink: placeholders and struck-out originals only.
    static let pkInk3 = PK.ink3Pair.color
    /// Solid Plate: keycaps, inputs, popup buttons.
    static let pkPlate = PK.platePair.color
    static let pkRule = PK.rulePair.color
    static let pkWash = PK.washPair.color
    static let pkWashDeep = PK.washDeepPair.color
    static let pkRow = PK.rowPair.color
}

extension PK {
    enum Radius {
        static let keycapSmall: CGFloat = 5
        static let popup: CGFloat = 7
        static let field: CGFloat = 8
        static let segment: CGFloat = 10
        static let row: CGFloat = 14
        static let menu: CGFloat = 18
        static let window: CGFloat = 20
        static let capsule: CGFloat = 11
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let pane: CGFloat = 26
    }

    /// The type scale. System font only; emphasis is weight, never another face.
    enum Font {
        static let heroWord = SwiftUI.Font.system(size: 60, weight: .bold)
        static let largeTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        static let title = SwiftUI.Font.system(size: 22, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 15, weight: .bold)
        static let groupTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let callout = SwiftUI.Font.system(size: 14)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let caption = SwiftUI.Font.system(size: 12)
        static let captionStrong = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let tag = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let keycap = SwiftUI.Font.system(size: 12.5, weight: .semibold)
    }

    /// Motion: springs only on switches, segment thumbs and the capsule; the
    /// rest eases out. All of it goes through `pkAnimation`, which honors
    /// Reduce Motion.
    enum Motion {
        /// cubic-bezier(.2,1.3,.3,1), .3-.5s
        static let spring = Animation.spring(response: 0.34, dampingFraction: 0.62)
        static let thumbSpring = Animation.spring(response: 0.42, dampingFraction: 0.68)
        /// cubic-bezier(.16,1,.3,1)
        static func easeOut(_ duration: Double = 0.32) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
        /// cubic-bezier(.2,1,.3,1)
        static func settle(_ duration: Double = 0.55) -> Animation { .timingCurve(0.2, 1, 0.3, 1, duration: duration) }
        /// Glass strip correction: cubic-bezier(.3,.7,.2,1), .95s
        static let strip = Animation.timingCurve(0.3, 0.7, 0.2, 1, duration: 0.95)
        static let press = Animation.easeOut(duration: 0.15)
    }
}

private struct PKAnimation<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `animation(_:value:)` that turns itself off under Reduce Motion.
    func pkAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(PKAnimation(animation: animation, value: value))
    }
}
