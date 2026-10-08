// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics
import Foundation

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
            completion(Self.locate())
        }
    }

    /// AX uses the top-left of the primary display as origin, AppKit the
    /// bottom-left.
    public static func appKitRect(fromAX rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func locate() -> CGRect? {
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
        for candidate in candidates where candidate.range.location >= 0 {
            guard var rect = bounds(of: element, in: candidate.range), rect.height > 0 else { continue }
            if candidate.atRightEdge { rect = CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height) }
            let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
            return appKitRect(fromAX: rect, primaryHeight: primaryHeight)
        }
        return nil
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
