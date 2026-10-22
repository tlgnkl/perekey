// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics
import Foundation

/// The caret and the frame of the focused element, both in AppKit screen
/// coordinates. The field frame lets the placement tell a caret an app reports
/// wrongly from a good one.
public struct CaretAnchor: Equatable, Sendable {
    public var caret: CGRect
    public var field: CGRect?

    public init(caret: CGRect, field: CGRect?) {
        self.caret = caret
        self.field = field
    }
}

/// Finds the caret of the focused element on screen, for the hint.
///
/// Runs on a thread of its own with the same AX timeout as `TextProbe`: an
/// app that hangs must not block the main thread or the tap thread. The
/// completion is called on that thread.
public final class CaretLocator: Sendable {
    private let thread = RunLoopThread(name: "Perekey AX caret", qualityOfService: .userInitiated)

    public init() {}

    deinit {
        thread.stop()
    }

    /// The caret rectangle in AppKit screen coordinates (origin bottom-left),
    /// or nil without the permission, a focused element, or an answer.
    public func caretRect(_ completion: @escaping @Sendable (CGRect?) -> Void) {
        thread.perform {
            completion(Self.locate()?.caret)
        }
    }

    /// The caret and the field frame, or nil as `caretRect`.
    public func anchor(_ completion: @escaping @Sendable (CaretAnchor?) -> Void) {
        thread.perform {
            completion(Self.locate())
        }
    }

    /// AX uses the top-left of the primary display as origin, AppKit the
    /// bottom-left.
    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func locate() -> CaretAnchor? {
        guard let element = TextProbe.focusedElement() else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
            == .success, let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeValue, to: AXValue.self), .cfRange, &selection),
              selection.location != kCFNotFound, selection.location >= 0
        else { return nil }

        // Bounds of an empty range are often not answered at the end of the
        // text; then the character before the caret, and its right edge.
        let candidates: [(range: CFRange, atRightEdge: Bool)] = [
            (CFRange(location: selection.location, length: 0), false),
            (CFRange(location: selection.location, length: 1), false),
            (CFRange(location: selection.location - 1, length: 1), true),
        ]
        var rangeCaret: CGRect?
        for candidate in candidates where candidate.range.location >= 0 {
            guard var rect = bounds(of: element, in: candidate.range), rect.height > 0 else { continue }
            if candidate.atRightEdge { rect = CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height) }
            rangeCaret = rect
            break
        }
        // A text element that answers no bounds: its own frame, when it is
        // one line high.
        let field = frame(of: element)
        guard let caret = rangeCaret ?? field.flatMap(Self.caret(fromLineFrame:)) else { return nil }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CaretAnchor(
            caret: appKitRect(fromAX: caret, primaryHeight: primaryHeight),
            field: field.map { appKitRect(fromAX: $0, primaryHeight: primaryHeight) }
        )
    }

    /// Tallest frame still read as one line of text.
    public static let maxLineHeight: CGFloat = 40

    /// The caret at the left edge of a one-line frame, or nil for a taller or
    /// empty one. Terminals on xterm.js (Orca, VS Code) type into an empty
    /// textarea that answers no bounds for a range, but they keep it on the
    /// cursor cell; a one-line field is still better than the screen corner.
    public static func caret(fromLineFrame frame: CGRect) -> CGRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.height > 0, frame.height <= maxLineHeight
        else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: 0, height: frame.height)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func bounds(of element: AXUIElement, in range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect != .zero
        else { return nil }
        return rect
    }
}
