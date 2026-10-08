// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyInput

@Suite struct LaggingAXAppsTests {
    private static let slack = URL(fileURLWithPath: "/Applications/Slack.app")

    // Runs where Slack (an Electron app) is installed; CI runners have none.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: slack.path)))
    func electronAppLags() {
        #expect(LaggingAXApps.isLagging(bundleURL: Self.slack))
    }

    @Test func nativeAppsDoNot() {
        #expect(!LaggingAXApps.isLagging(bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")))
        #expect(!LaggingAXApps.isLagging(bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")))
        #expect(!LaggingAXApps.isLagging(bundleURL: nil))
    }
}
