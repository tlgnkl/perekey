// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyInput

@Suite struct HintLifetimeTests {
    private func type(_ word: String, into life: inout HintLifetime, at start: Double, step: Double = 0.1) -> Double {
        var now = start
        for character in word {
            let key = HintKey.classify(keyCode: 0, character: character, isShortcut: false)
            life.record(key, at: now)
            now += step
        }
        return now
    }

    @Test func goesAfterThreeIdleSeconds() {
        let life = HintLifetime(now: 10)
        #expect(!life.isExpired(at: 12.9))
        #expect(life.isExpired(at: 13))
    }

    @Test func everyKeyPressExtendsTheWait() {
        var life = HintLifetime(now: 0)
        life.record(.wordCharacter, at: 2)
        #expect(!life.isExpired(at: 4.9))
        #expect(life.isExpired(at: 5))
    }

    @Test func goesWhenTheNextWordIsTypedInFull() {
        var life = HintLifetime(now: 0)
        let now = type("привет", into: &life, at: 0.5)
        #expect(!life.isExpired(at: now))
        life.record(.wordBoundary, at: now)
        #expect(life.isExpired(at: now))
    }

    @Test func aBoundaryWithoutAWordDoesNotCount() {
        var life = HintLifetime(now: 0)
        life.record(.wordBoundary, at: 0.2)
        life.record(.wordBoundary, at: 0.3)
        #expect(!life.isExpired(at: 0.4))
    }

    @Test func deletingTheWordTakesTheCountBack() {
        var life = HintLifetime(now: 0)
        life.record(.wordCharacter, at: 0.1)
        life.record(.delete, at: 0.2)
        life.record(.wordBoundary, at: 0.3)
        #expect(!life.isExpired(at: 0.4))
    }

    @Test func shortcutsAndArrowsOnlyKeepItAlive() {
        var life = HintLifetime(now: 0)
        life.record(.other, at: 2)
        #expect(!life.isExpired(at: 4))
    }

    @Test func hoverHoldsTheHint() {
        var life = HintLifetime(now: 0)
        life.setHovering(true, at: 1)
        #expect(!life.isExpired(at: 60))
        life.setHovering(false, at: 60)
        // Two seconds were left when the pointer arrived.
        #expect(!life.isExpired(at: 61.9))
        #expect(life.isExpired(at: 62))
    }

    @Test func hoverHoldsEvenAFinishedWordUntilItLeaves() {
        var life = HintLifetime(now: 0)
        life.setHovering(true, at: 0.5)
        life.record(.wordCharacter, at: 1)
        life.record(.wordBoundary, at: 1.1)
        #expect(!life.isExpired(at: 1.2))
        life.setHovering(false, at: 5)
        #expect(life.isExpired(at: 5))
    }

    @Test func aKeyWhileHoveredRestoresTheFullWait() {
        var life = HintLifetime(now: 0)
        life.setHovering(true, at: 2.5)
        life.record(.other, at: 3)
        life.setHovering(false, at: 10)
        #expect(!life.isExpired(at: 12.9))
        #expect(life.isExpired(at: 13))
    }

    @Test func restartCountsFromScratch() {
        var life = HintLifetime(now: 0)
        life.record(.wordCharacter, at: 0.1)
        life.record(.wordBoundary, at: 0.2)
        #expect(life.isExpired(at: 0.3))
        life.restart(at: 1)
        #expect(!life.isExpired(at: 3.9))
        #expect(life.isExpired(at: 4))
    }

    @Test func holdKeepsTheHintForTheReader() {
        var life = HintLifetime(now: 0)
        life.hold(for: 10, at: 1)
        #expect(!life.isExpired(at: 10.9))
        #expect(life.isExpired(at: 11))
        // A hold never shortens the wait.
        var longer = HintLifetime(now: 0)
        longer.record(.other, at: 20)
        longer.hold(for: 1, at: 20)
        #expect(!longer.isExpired(at: 22.9))
    }

    @Test func holdAlsoLengthensWhatTheHoverFroze() {
        var life = HintLifetime(now: 0)
        life.setHovering(true, at: 2.5)
        life.hold(for: 10, at: 2.6)
        life.setHovering(false, at: 5)
        #expect(!life.isExpired(at: 14.9))
        #expect(life.isExpired(at: 15))
    }

    @Test func classifiesKeys() {
        func kind(_ code: UInt16, _ character: Character?, shortcut: Bool = false) -> HintKey {
            HintKey.classify(keyCode: code, character: character, isShortcut: shortcut)
        }
        #expect(kind(0, "a") == .wordCharacter)
        #expect(kind(0, "я") == .wordCharacter)
        #expect(kind(18, "1") == .wordCharacter)
        #expect(kind(49, " ") == .wordBoundary)
        #expect(kind(43, ",") == .wordBoundary)
        #expect(kind(36, "\r") == .wordBoundary)
        #expect(kind(48, "\t") == .wordBoundary)
        #expect(kind(51, nil) == .delete)
        #expect(kind(123, nil) == .other)
        #expect(kind(0, "a", shortcut: true) == .other)
        #expect(kind(122, nil) == .other)
    }
}

@Suite struct GlassStripTimelineTests {
    @Test func startsAndEndsAtRest() {
        let start = GlassStripTimeline.frame(at: 0)
        #expect(start == .init(cover: 0, peel: 0, swap: 0))
        #expect(!start.stripVisible)
        let end = GlassStripTimeline.frame(at: 1)
        #expect(end == .init(cover: 1, peel: 1, swap: 1))
        #expect(!end.stripVisible)
    }

    @Test func theWordSwapsWhileTheStripCoversIt() {
        for step in 0 ... 100 {
            let frame = GlassStripTimeline.frame(at: Double(step) / 100)
            if frame.swap > 0.05, frame.swap < 0.95 {
                #expect(frame.cover > 0.95, "swap at \(step)% is visible")
                #expect(frame.peel < 0.05, "swap at \(step)% is visible")
            }
        }
    }

    @Test func edgesOnlyMoveForward() {
        var last = GlassStripTimeline.frame(at: 0)
        for step in 1 ... 100 {
            let frame = GlassStripTimeline.frame(at: Double(step) / 100)
            #expect(frame.cover >= last.cover && frame.peel >= last.peel && frame.swap >= last.swap)
            last = frame
        }
    }

    @Test func reducedMotionCrossFadesWithoutAStrip() {
        for step in 0 ... 10 {
            let frame = GlassStripTimeline.frame(at: Double(step) / 10, reducedMotion: true)
            #expect(!frame.stripVisible)
        }
        #expect(GlassStripTimeline.frame(at: 1, reducedMotion: true).swap == 1)
        #expect(GlassStripTimeline.frame(at: 0.5, reducedMotion: true).swap > 0)
    }

    @Test func bezierEndpointsAndMonotony() {
        let curve = CubicBezier.strip
        #expect(curve.value(at: 0) == 0)
        #expect(curve.value(at: 1) == 1)
        var last = 0.0
        for step in 1 ... 50 {
            let value = curve.value(at: Double(step) / 50)
            #expect(value >= last)
            last = value
        }
        // Front-loaded: well past half at the midpoint.
        #expect(curve.value(at: 0.5) > 0.75)
    }
}
