// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct AccessPolicyTests {
    @Test func reopenWithoutAccessOpensTheAccessStep() {
        #expect(AccessPolicy.reopen(hasAccess: false) == .onboardingAccess)
        #expect(AccessPolicy.reopen(hasAccess: true) == .settings)
    }

    @Test func reopenBeforeOnboardingIsDoneStartsItFromTheWelcome() {
        #expect(AccessPolicy.reopen(hasAccess: false, onboardingDone: false) == .onboarding)
        #expect(AccessPolicy.reopen(hasAccess: true, onboardingDone: false) == .onboarding)
    }

    @Test func bannerShowsOnlyWithoutAccess() {
        #expect(AccessPolicy.showsBanner(hasAccess: false))
        #expect(!AccessPolicy.showsBanner(hasAccess: true))
    }

    @Test func revokedWhileTheTapsExistWithoutTrust() {
        // Running or suspended: the taps exist, and the system says no.
        #expect(AccessPolicy.isRevoked(waitingForAccess: false, trusted: false))
        #expect(!AccessPolicy.isRevoked(waitingForAccess: false, trusted: true))
        // Already waiting for access: nothing to drop.
        #expect(!AccessPolicy.isRevoked(waitingForAccess: true, trusted: false))
        #expect(!AccessPolicy.isRevoked(waitingForAccess: true, trusted: true))
    }

    @Test func rechecksFollowTheLagInOrder() {
        let delays = AccessPolicy.recheckDelays
        #expect(delays.count >= 2)
        #expect(delays == delays.sorted() && Set(delays).count == delays.count)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(AccessPolicy.pollInterval >= 1)
    }
}
