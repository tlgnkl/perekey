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
}
