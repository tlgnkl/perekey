// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Hatch

/// The 135-degree hatch: "time, zone or text Perekey does not count". Used only
/// for the held capsule, the held-state tile, never-touched rows and forgotten words.
struct Hatch: View {
    var color: Color = .pkWashDeep
    var on: CGFloat = 3
    var off: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let step = (on + off) * 2.0.squareRoot()
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color), lineWidth: on)
                x += step
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Glass strip

/// The strip surface: gradient, 0.5pt light rim, indigo glow. This is the
/// fallback and the look used wherever Liquid Glass cannot draw (an image for
/// the menu bar, macOS 14 and 15).
struct StripFill<S: InsettableShape>: View {
    let shape: S
    /// `nil` follows the environment; the menu bar image passes its own.
    var dark: Bool?
    var glow = true
    var pressed = false
    var glowRadius: CGFloat = 8
    var glowOffset: CGFloat = 5

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let isDark = dark ?? (scheme == .dark)
        let increased = contrast == .increased
        shape
            .fill(LinearGradient(
                colors: isDark
                    ? [.white.opacity(0.20), Color(red: 140 / 255, green: 138 / 255, blue: 1).opacity(0.16)]
                    : [.white.opacity(0.78), Color(red: 222 / 255, green: 222 / 255, blue: 1).opacity(0.50)],
                startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(PK.mistPair.resolved(dark: isDark)))
            .overlay(
                shape.strokeBorder(.white.opacity(isDark ? (increased ? 0.5 : 0.22) : 0.95), lineWidth: increased ? 1 : 0.5)
            )
            .shadow(color: glow ? PK.glowPair.resolved(dark: isDark).opacity(pressed ? 0.5 : 1) : .clear, radius: glowRadius, x: 0, y: glowOffset)
    }
}

private struct LiquidGlassKey: EnvironmentKey {
    /// On unless turned off with `defaults write app.perekey.Perekey LiquidGlass -bool false`:
    /// a way out if real Liquid Glass hides something, since snapshots cannot draw it.
    static let defaultValue = UserDefaults.standard.object(forKey: "LiquidGlass") as? Bool ?? true
}

extension EnvironmentValues {
    /// `false` draws every glass surface with the macOS 14 look (materials and
    /// the gradient strip). Offscreen snapshots use it: Liquid Glass samples the
    /// screen behind a window, and an offscreen window has none.
    var pkLiquidGlass: Bool {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
}

private struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.pkLiquidGlass) private var liquid

    func body(content: Content) -> some View {
        if #available(macOS 26, *), liquid {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a material before it. For controls and bars
    /// that float over content.
    func pkGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassModifier(shape: shape, tint: tint, interactive: interactive))
    }

    /// The signature strip as a background: Liquid Glass tinted with Indigo
    /// Mist on macOS 26+, the gradient strip before that. Rim and glow on both.
    func glassStrip<S: InsettableShape>(in shape: S, glow: Bool = true, pressed: Bool = false) -> some View {
        modifier(GlassStripModifier(shape: shape, glow: glow, pressed: pressed))
    }
}

private struct GlassStripModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let glow: Bool
    let pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pkLiquidGlass) private var liquid

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency, liquid {
            content
                .glassEffect(.regular.tint(PK.mistPair.resolved(dark: scheme == .dark)), in: shape)
                .background {
                    if glow { shape.fill(.clear).shadow(color: PK.glowPair.resolved(dark: scheme == .dark), radius: 8, x: 0, y: 5) }
                }
        } else {
            content.background { StripFill(shape: shape, glow: glow, pressed: pressed) }
        }
    }
}

// MARK: - Cards

/// A grouped surface: Row fill, 0.5pt rim, radius 14.
struct PKCard: ViewModifier {
    var radius: CGFloat = PK.Radius.row

    func body(content: Content) -> some View {
        content
            .background(Color.pkRow, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func pkCard(radius: CGFloat = PK.Radius.row) -> some View { modifier(PKCard(radius: radius)) }
}

/// A 1pt hairline between rows.
struct PKDivider: View {
    var leading: CGFloat = PK.Space.lg
    var trailing: CGFloat = 0

    var body: some View {
        Rectangle().fill(Color.pkRule).frame(height: 1).padding(.leading, leading).padding(.trailing, trailing)
            .accessibilityHidden(true)
    }
}

/// The icon tile of a held-state card or a never-touched row: a hatched square.
struct HatchTile: View {
    let symbol: String
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Color.pkWash)
            Hatch(color: .pkWashDeep)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(Color.pkInk)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
