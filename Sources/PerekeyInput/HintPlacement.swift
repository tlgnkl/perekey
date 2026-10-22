// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import OSLog

/// Where the caret hint goes. Pure geometry in AppKit screen coordinates
/// (origin bottom-left), so the flip and clamp rules are unit-testable.
public enum HintPlacement {
    /// Gap between the caret and the hint.
    public static let gap: CGFloat = 6
    /// Margin kept to the edge of the visible frame.
    public static let margin: CGFloat = 8

    /// Which rule decided a placement, for the log.
    public enum Rule: String, Sendable {
        /// Under the trusted caret.
        case caret
        /// Under the field, the caret not being trusted.
        case field
        /// Above the caret or the field, the room below being too small.
        case flipped
        /// Neither side fits within the margin: past the margin, or clamped.
        case fallback
    }

    public struct Placement: Equatable, Sendable {
        public var origin: CGPoint
        public var rule: Rule
    }

    /// Caret rectangles may lie up to this far outside the field and still count.
    public static let fieldTolerance: CGFloat = 2

    /// Just below the caret, flipped above when it would leave the visible
    /// frame at the bottom, then clamped to the frame. Returns the origin of a
    /// hint of `size`.
    public static func origin(size: CGSize, caret: CGRect, visible: CGRect) -> CGPoint {
        place(size: size, anchor: CaretAnchor(caret: caret, field: nil), visible: visible).origin
    }

    /// Where a hint of `size` goes for `anchor`.
    ///
    /// An app may report a caret that is wrong (shifted a line, or outside the
    /// window), so a caret not inside the field frame (give or take
    /// `fieldTolerance`) is not trusted; the hint then anchors to the field. A
    /// caret without a field frame is trusted.
    ///
    /// The bubble never covers the keep-clear rect: the trusted caret's line,
    /// or the whole field when the caret is not trusted. The order is: below it,
    /// then above it, both within the margin; then, past the margin but inside
    /// the visible frame, the side with more room first. Only when the bubble
    /// is too tall for either side does it fall back to the plain clamp, over
    /// the text.
    public static func place(size: CGSize, anchor: CaretAnchor, visible: CGRect) -> Placement {
        let trusted = anchor.field.map { $0.insetBy(dx: -fieldTolerance, dy: -fieldTolerance).contains(anchor.caret) } ?? true
        let keepClear = trusted ? anchor.caret : anchor.field ?? anchor.caret
        var x = anchor.caret.minX - 10
        if let field = anchor.field, !trusted {
            x = anchor.caret.minX >= field.minX && anchor.caret.minX <= field.maxX ? anchor.caret.minX - 10 : field.minX
        }
        let below = keepClear.minY - gap - size.height
        let above = keepClear.maxY + gap
        let belowRule: Rule = trusted ? .caret : .field

        func clear(_ y: CGFloat, margin: CGFloat) -> Bool {
            y >= visible.minY + margin && y <= visible.maxY - size.height - margin
                && !CGRect(x: x, y: y, width: size.width, height: size.height).intersects(keepClear)
        }
        func result(_ y: CGFloat, _ rule: Rule) -> Placement {
            Placement(origin: clamp(CGPoint(x: x, y: y), size: size, visible: visible), rule: rule)
        }

        if clear(below, margin: margin) { return result(below, belowRule) }
        if clear(above, margin: margin) { return result(above, .flipped) }
        // Past the margin: the side with more room first.
        let belowRoom = keepClear.minY - visible.minY
        let aboveRoom = visible.maxY - keepClear.maxY
        let sides = belowRoom >= aboveRoom ? [below, above] : [above, below]
        for y in sides where clear(y, margin: 0) {
            return Placement(origin: CGPoint(x: clamp(CGPoint(x: x, y: y), size: size, visible: visible).x, y: y),
                             rule: .fallback)
        }
        // Too tall for both sides: the old rule, over the text.
        return result(below < visible.minY + margin ? above : below, .fallback)
    }

    /// One debug line per placement. Numbers and the app only, never text.
    public static func log(bundleID: String?, anchor: CaretAnchor, visible: CGRect, placement: Placement) {
        let app = bundleID ?? "?"
        func rect(_ r: CGRect?) -> String {
            guard let r else { return "none" }
            return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        let origin = placement.origin
        let rule = placement.rule.rawValue
        let caret = rect(anchor.caret), field = rect(anchor.field), frame = rect(visible)
        logger.debug("Hint in \(app, privacy: .public): caret \(caret, privacy: .public), field \(field, privacy: .public), visible \(frame, privacy: .public), rule \(rule, privacy: .public), origin \(Int(origin.x), privacy: .public),\(Int(origin.y), privacy: .public)")
    }

    private static let logger = Logger(subsystem: "app.perekey", category: "hint")

    /// Without a caret: the top right of the visible frame, under the menu bar
    /// where the capsule is.
    public static func fallbackOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - margin),
              size: size, visible: visible)
    }

    /// Without a caret, for the dictation HUD: at the bottom, centred on the
    /// pointer's screen (`visible`), above the Dock.
    public static func bottomCenterOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        clamp(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 48), size: size, visible: visible)
    }

    public static func clamp(_ origin: CGPoint, size: CGSize, visible: CGRect, margin: CGFloat = margin) -> CGPoint {
        let maxX = max(visible.minX, visible.maxX - size.width - margin)
        let maxY = max(visible.minY, visible.maxY - size.height - margin)
        return CGPoint(
            x: min(max(origin.x, visible.minX + margin), maxX),
            y: min(max(origin.y, visible.minY + margin), maxY)
        )
    }
}
