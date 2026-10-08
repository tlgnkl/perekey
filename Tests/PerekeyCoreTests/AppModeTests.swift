// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct AppModeTests {
    @Test func builtIns() {
        let settings = AppSettings()
        #expect(settings.effectiveMode(bundleID: "com.apple.Terminal", isGame: false) == .manualOnly)
        #expect(settings.effectiveMode(bundleID: "com.jetbrains.intellij", isGame: false) == .manualOnly)
        #expect(settings.effectiveMode(bundleID: "com.apple.Notes", isGame: false) == .auto)
        #expect(settings.effectiveMode(bundleID: "com.example.game", isGame: true) == .off)
    }

    @Test func userRuleWinsOverBuiltIns() {
        let settings = AppSettings(apps: [
            "com.apple.Terminal": AppRule(mode: .auto),
            "com.example.game": AppRule(mode: .auto),
            "com.apple.Notes": AppRule(mode: .off),
        ])
        #expect(settings.effectiveMode(bundleID: "com.apple.Terminal", isGame: false) == .auto)
        #expect(settings.effectiveMode(bundleID: "com.example.game", isGame: true) == .auto)
        #expect(settings.effectiveMode(bundleID: "com.apple.Notes", isGame: false) == .off)
    }

    @Test func gameCategory() {
        #expect(AppModes.isGame(category: "public.app-category.games"))
        #expect(AppModes.isGame(category: "public.app-category.action-games"))
        #expect(!AppModes.isGame(category: "public.app-category.productivity"))
        #expect(!AppModes.isGame(category: nil))
    }

    @Test func roundTripAndTolerantDecoding() throws {
        let rule = AppRule(mode: .manualOnly, defaultLayout: "com.apple.keylayout.ABC", rememberLastLayout: true)
        let settings = AppSettings(apps: ["a.b": rule])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.apps.isEmpty)
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"apps":{"x":{"mode":"laser"},"y":{}}}"#.utf8))
        #expect(odd.apps["x"] == AppRule())
        #expect(odd.apps["y"] == AppRule())
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"apps":[1,2]}"#.utf8))
        #expect(broken.apps.isEmpty)
    }
}
