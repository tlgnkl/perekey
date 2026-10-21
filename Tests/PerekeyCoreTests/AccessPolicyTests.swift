// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct AccessPolicyTests {
    @Test func reopenWithoutAccessOpensTheAccessStep() {
        #expect(AccessPolicy.reopen(hasAccess: false) == .onboardingAccess)
        #expect(AccessPolicy.reopen(hasAccess: true) == .settings)
    }

    @Test func bannerShowsOnlyWithoutAccess() {
        #expect(AccessPolicy.showsBanner(hasAccess: false))
        #expect(!AccessPolicy.showsBanner(hasAccess: true))
    }

    @Test func revokedOnlyWhileTheTapsRunWithoutTrust() {
        #expect(AccessPolicy.isRevoked(tapRunning: true, trusted: false))
        #expect(!AccessPolicy.isRevoked(tapRunning: true, trusted: true))
        // Already waiting for access: nothing to drop.
        #expect(!AccessPolicy.isRevoked(tapRunning: false, trusted: false))
        #expect(!AccessPolicy.isRevoked(tapRunning: false, trusted: true))
    }

    @Test func rechecksFollowTheLagInOrder() {
        let delays = AccessPolicy.recheckDelays
        #expect(delays.count >= 2)
        #expect(delays == delays.sorted() && Set(delays).count == delays.count)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(AccessPolicy.pollInterval >= 1)
    }
}
