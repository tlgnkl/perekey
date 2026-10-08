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

/// The signature capsule: the layout code in Indigo Ink on an Indigo Mist strip
/// with a 1pt ring; a pause reason adds its glyph and text before the code.
/// Colors come from `dark`, not from the environment, because the image for the
/// menu bar is rendered outside any view hierarchy.
struct CapsuleView: View {
    let model: CapsuleModel
    let dark: Bool
    var height: CGFloat = 20
    var fontSize: CGFloat = 11.5

    private var ink: Color { dark ? Color(red: 0xA9 / 255, green: 0xA7 / 255, blue: 1) : Color(red: 0x46 / 255, green: 0x44 / 255, blue: 0xD0 / 255) }
    private var mist: Color { dark ? Color(red: 125 / 255, green: 122 / 255, blue: 1).opacity(0.18) : Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255).opacity(0.13) }
    private var ring: Color { Color(red: 94 / 255, green: 92 / 255, blue: 230 / 255).opacity(dark ? 0.55 : 0.35) }

    var body: some View {
        HStack(spacing: 4) {
            if let reason = model.reason {
                Image(systemName: reason.symbol)
                    .font(.system(size: fontSize - 1.5, weight: .bold))
                Text(reason.capsuleText(now: model.now))
                    .font(.system(size: fontSize - 1.5, weight: .semibold))
                    .lineLimit(1)
                Rectangle().fill(ring).frame(width: 1, height: height * 0.45)
            }
            Text(model.code)
                .font(.system(size: fontSize, weight: .heavy))
                .tracking(0.06 * fontSize)
                .strikethrough(model.struck, color: ink)
                .opacity(model.struck ? 0.7 : 1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, height * 0.4)
        .frame(minWidth: height * 2.1, minHeight: height, maxHeight: height)
        .background(Capsule().fill(mist))
        .overlay(Capsule().strokeBorder(ring, lineWidth: 1))
        .fixedSize()
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
