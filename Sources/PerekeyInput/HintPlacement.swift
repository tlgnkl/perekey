// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Where the caret hint goes. Pure geometry in AppKit screen coordinates
/// (origin bottom-left), so the flip and clamp rules are unit-testable.
public enum HintPlacement {
    /// Gap between the caret and the hint.
    public static let gap: CGFloat = 6
    /// Margin kept to the edge of the visible frame.
    public static let margin: CGFloat = 8

    /// Just below the caret, flipped above when it would leave the visible
    /// frame at the bottom, then clamped to the frame. Returns the origin of a
    /// hint of `size`.
    public static func origin(size: CGSize, caret: CGRect, visible: CGRect) -> CGPoint {
        var y = caret.minY - gap - size.height
        if y < visible.minY + margin { y = caret.maxY + gap }
        return clamp(CGPoint(x: caret.minX - 10, y: y), size: size, visible: visible)
    }

    /// Without a caret: the top right of the visible frame, under the menu bar
    /// where the capsule is.
    public static func fallbackOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - margin),
              size: size, visible: visible)
    }

    public static func clamp(_ origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        let maxX = max(visible.minX, visible.maxX - size.width - margin)
        let maxY = max(visible.minY, visible.maxY - size.height - margin)
        return CGPoint(
            x: min(max(origin.x, visible.minX + margin), maxX),
            y: min(max(origin.y, visible.minY + margin), maxY)
        )
    }
}
