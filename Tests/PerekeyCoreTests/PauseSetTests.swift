// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct PauseSetTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func emptyShowsNothing() {
        #expect(PauseSet().top(at: now) == nil)
        #expect(PauseSet().nextDeadline == nil)
    }

    @Test func priorityOrder() {
        var set = PauseSet()
        let deadline = now.addingTimeInterval(3600)
        set.setAppOff(app: "Notes")
        #expect(set.top(at: now) == .appOff(app: "Notes"))
        set.pause(until: deadline)
        #expect(set.top(at: now) == .timed(until: deadline))
        set.setSecureInput(true, owner: "1Password")
        #expect(set.top(at: now) == .secureInput(owner: "1Password"))
        set.setPasswordField(true)
        #expect(set.top(at: now) == .passwordField)
        #expect(set.reasons(at: now).count == 4)
    }

    @Test func expiredPauseIsNotShownEvenBeforeExpire() {
        var set = PauseSet()
        set.pause(until: now.addingTimeInterval(60))
        #expect(set.top(at: now.addingTimeInterval(61)) == nil)
        #expect(set.expire(at: now.addingTimeInterval(30)) == false)
        #expect(set.expire(at: now.addingTimeInterval(60)) == true)
        #expect(set.nextDeadline == nil)
    }

    @Test func clearingSecureInputForgetsOwner() {
        var set = PauseSet()
        set.setSecureInput(true, owner: "X")
        set.setSecureInput(false)
        #expect(set.secureInputOwner == nil)
        #expect(set.top(at: now) == nil)
    }

    @Test func minutesRoundUp() {
        #expect(PauseSet.minutesLeft(until: now.addingTimeInterval(3600), at: now) == 60)
        #expect(PauseSet.minutesLeft(until: now.addingTimeInterval(3541), at: now) == 60)
        #expect(PauseSet.minutesLeft(until: now.addingTimeInterval(1), at: now) == 1)
        #expect(PauseSet.minutesLeft(until: now.addingTimeInterval(-5), at: now) == 1)
    }
}
