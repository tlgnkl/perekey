// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing
@testable import PerekeyInput

@Suite struct HintPlacementTests {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 30)

    @Test func belowTheCaret() {
        let caret = CGRect(x: 300, y: 400, width: 0, height: 16)
        let origin = HintPlacement.origin(size: size, caret: caret, visible: visible)
        #expect(origin.y == 400 - HintPlacement.gap - 30)
        #expect(origin.x == 290)
    }

    @Test func flipsAboveNearTheBottom() {
        let caret = CGRect(x: 300, y: 20, width: 0, height: 16)
        let origin = HintPlacement.origin(size: size, caret: caret, visible: visible)
        #expect(origin.y == 36 + HintPlacement.gap)
    }

    @Test func clampsToTheRightAndLeftEdges() {
        let right = HintPlacement.origin(size: size, caret: CGRect(x: 990, y: 400, width: 0, height: 16), visible: visible)
        #expect(right.x == 1000 - 200 - HintPlacement.margin)
        let left = HintPlacement.origin(size: size, caret: CGRect(x: 2, y: 400, width: 0, height: 16), visible: visible)
        #expect(left.x == HintPlacement.margin)
    }

    @Test func staysBelowNearTheTop() {
        // Room below the caret: no flip, and the hint stays inside the frame.
        let origin = HintPlacement.origin(size: size, caret: CGRect(x: 300, y: 790, width: 0, height: 16), visible: visible)
        #expect(origin.y == 790 - HintPlacement.gap - 30)
    }

    @Test func tallHintIsClampedInside() {
        // Neither below nor above fits a hint this tall: clamp to the top edge.
        let tall = CGSize(width: 200, height: 780)
        let origin = HintPlacement.origin(size: tall, caret: CGRect(x: 300, y: 400, width: 0, height: 16), visible: visible)
        #expect(origin.y == max(0, 800 - 780 - HintPlacement.margin))
    }

    @Test func fallbackIsTopRight() {
        let origin = HintPlacement.fallbackOrigin(size: size, visible: visible)
        #expect(origin == CGPoint(x: 1000 - 200 - 12, y: 800 - 30 - HintPlacement.margin))
    }

    @Test func convertsAXCoordinates() {
        let rect = CaretLocator.appKitRect(fromAX: CGRect(x: 10, y: 100, width: 2, height: 20), primaryHeight: 900)
        #expect(rect == CGRect(x: 10, y: 780, width: 2, height: 20))
    }

    @Test func oneLineFrameIsACaretAtItsLeftEdge() {
        // xterm.js keeps its input textarea on the cursor cell.
        let caret = CaretLocator.caret(fromLineFrame: CGRect(x: 120, y: 700, width: 8, height: 17))
        #expect(caret == CGRect(x: 120, y: 700, width: 0, height: 17))
        let limit = CaretLocator.caret(fromLineFrame: CGRect(x: 0, y: 0, width: 300, height: CaretLocator.maxLineHeight))
        #expect(limit?.height == CaretLocator.maxLineHeight)
    }

    @Test func tallOrEmptyFrameIsNoCaret() {
        #expect(CaretLocator.caret(fromLineFrame: CGRect(x: 0, y: 0, width: 600, height: 400)) == nil)
        #expect(CaretLocator.caret(fromLineFrame: CGRect(x: 0, y: 0, width: 8, height: 0)) == nil)
        #expect(CaretLocator.caret(fromLineFrame: CGRect(x: CGFloat.nan, y: 0, width: 8, height: 17)) == nil)
    }

    @Test func withoutACaretTheHUDSitsAtTheBottomCentre() {
        let origin = HintPlacement.bottomCenterOrigin(size: size, visible: visible)
        #expect(origin.x == 400)
        #expect(origin.y == 48)
        // A second screen: the centre of its own visible frame.
        let second = CGRect(x: 1000, y: -200, width: 1600, height: 900)
        let other = HintPlacement.bottomCenterOrigin(size: size, visible: second)
        #expect(other.x == 1700 && other.y == -152)
    }

    // MARK: - Caret against the field

    private func overlaps(_ origin: CGPoint, _ rect: CGRect) -> Bool {
        CGRect(origin: origin, size: size).intersects(rect)
    }

    @Test func caretInsideTheFieldChangesNothing() {
        let caret = CGRect(x: 300, y: 400, width: 0, height: 16)
        let field = CGRect(x: 100, y: 390, width: 600, height: 40)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: field), visible: visible)
        #expect(placement.origin == HintPlacement.origin(size: size, caret: caret, visible: visible))
        #expect(placement.rule == .caret)
    }

    @Test func caretShiftedAboveTheFieldAnchorsToTheField() {
        // The app reports the caret a line too high.
        let field = CGRect(x: 100, y: 120, width: 600, height: 40)
        let caret = CGRect(x: 300, y: 170, width: 0, height: 16)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: field), visible: visible)
        #expect(placement.rule == .field)
        #expect(placement.origin.y == field.minY - HintPlacement.gap - size.height)
        #expect(!overlaps(placement.origin, field))
        #expect(placement.origin.x == 290)
    }

    @Test func fieldAtTheBottomPutsTheHintAbove() {
        let field = CGRect(x: 100, y: 10, width: 600, height: 40)
        let caret = CGRect(x: 300, y: 60, width: 0, height: 16)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: field), visible: visible)
        #expect(placement.rule == .flipped)
        #expect(placement.origin.y == field.maxY + HintPlacement.gap)
        #expect(!overlaps(placement.origin, field))
    }

    @Test func caretOutsideTheFieldSpanTakesTheFieldEdge() {
        let field = CGRect(x: 100, y: 400, width: 200, height: 40)
        let caret = CGRect(x: 900, y: 600, width: 0, height: 16)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: field), visible: visible)
        #expect(placement.origin.x == field.minX)
    }

    @Test func caretWithinTheToleranceIsTrusted() {
        let field = CGRect(x: 100, y: 400, width: 600, height: 40)
        let caret = CGRect(x: 300, y: 399, width: 0, height: 16)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: field), visible: visible)
        #expect(placement.rule == .caret)
    }

    @Test func caretBelowTheVisibleFrameNeverEndsOnItsLine() {
        // Case B: the caret is under the visible frame; the clamp used to push the hint onto it.
        let visible = CGRect(x: 0, y: 100, width: 1000, height: 700)
        let caret = CGRect(x: 300, y: 90, width: 0, height: 16)
        let placement = HintPlacement.place(size: size, anchor: CaretAnchor(caret: caret, field: nil), visible: visible)
        #expect(!overlaps(placement.origin, caret))
        #expect(placement.rule == .flipped)
    }

    @Test func tightSpaceGoesPastTheMarginNotOverTheLine() {
        // Above the line the hint fits the frame but not the margin; below it nothing fits.
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 80)
        let caret = CGRect(x: 300, y: 8, width: 0, height: 20)
        let small = CGSize(width: 200, height: 40)
        let placement = HintPlacement.place(size: small, anchor: CaretAnchor(caret: caret, field: nil), visible: visible)
        #expect(!CGRect(origin: placement.origin, size: small).intersects(caret))
        #expect(placement.rule == .fallback)
        #expect(placement.origin.y == caret.maxY + HintPlacement.gap)
    }
}
