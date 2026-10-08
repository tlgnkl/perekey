// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct UpdatePolicyTests {
    @Test func profileWinsOverEverything() {
        let policy = UpdatePolicy(configured: true, managed: ManagedSettings(updatesDisabled: true), checkAutomatically: true)
        #expect(policy.state == .managedOff)
        #expect(!policy.startsAtLaunch)
        #expect(!policy.canCheckNow)
        #expect(policy.isLocked)
    }

    @Test func unconfiguredBuildNeverStarts() {
        let policy = UpdatePolicy(configured: false, managed: ManagedSettings(), checkAutomatically: true)
        #expect(policy.state == .notConfigured)
        #expect(!policy.startsAtLaunch)
        #expect(!policy.canCheckNow)
        #expect(!policy.isLocked)
    }

    @Test func switchOffMeansNoStartButManualCheck() {
        let off = UpdatePolicy(configured: true, managed: ManagedSettings(), checkAutomatically: false)
        #expect(off.state == .manual)
        #expect(!off.startsAtLaunch)
        #expect(off.canCheckNow)
        let on = UpdatePolicy(configured: true, managed: ManagedSettings(), checkAutomatically: true)
        #expect(on.state == .automatic)
        #expect(on.startsAtLaunch)
    }

    @Test func onlyForcedTrueDisables() {
        #expect(ManagedSettings { _ in nil }.updatesDisabled == false)
        #expect(ManagedSettings { $0 == "UpdatesDisabled" ? true : nil }.updatesDisabled)
        #expect(ManagedSettings { $0 == "UpdatesDisabled" ? false : nil }.updatesDisabled == false)
        #expect(ManagedSettings { $0 == "UpdatesDisabled" ? "yes" : nil }.updatesDisabled == false)
    }

    @Test func feedNeedsHTTPSAndA32ByteKey() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(UpdateFeed.isConfigured(feedURL: UpdateFeed.url, publicKey: key))
        #expect(!UpdateFeed.isConfigured(feedURL: UpdateFeed.url, publicKey: "TO-CONFIGURE"))
        #expect(!UpdateFeed.isConfigured(feedURL: UpdateFeed.url, publicKey: Data(count: 16).base64EncodedString()))
        #expect(!UpdateFeed.isConfigured(feedURL: "http://example.org/appcast.xml", publicKey: key))
        #expect(!UpdateFeed.isConfigured(feedURL: nil, publicKey: key))
    }

    @Test func updatesAreOnByDefaultAndSurviveOldFiles() throws {
        #expect(AppSettings().checkForUpdates)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.checkForUpdates)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"checkForUpdates":false}"#.utf8))
        #expect(!off.checkForUpdates)
    }

    /// The privacy promise lives in Info.plist: one feed address, no system profile.
    @Test func infoPlistKeepsThePrivacyPromise() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Support/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String == UpdateFeed.url)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(plist["SUPublicEDKey"] is String)
    }
}
