// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct MenuBarIconTests {
    @Test func oldSettingsFileKeepsTheCapsuleAlways() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.menuBarIcon == .capsule)
        #expect(old.menuBarVisibility == .always)
    }

    @Test func unknownValuesFallBackToDefaults() throws {
        let json = #"{"menuBarIcon":"hologram","menuBarVisibility":"sometimes"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.menuBarIcon == .capsule)
        #expect(settings.menuBarVisibility == .always)
    }

    @Test func roundTripKeepsTheChoice() throws {
        var settings = AppSettings()
        settings.menuBarIcon = .mark
        settings.menuBarVisibility = .whenNeeded
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(back == settings)
        #expect(back.menuBarIcon == .mark && back.menuBarVisibility == .whenNeeded)
    }

    @Test func visibilityFollowsTheSituation() {
        let quiet = MenuBarSituation()
        let cases: [MenuBarSituation] = [
            .init(paused: true), .init(autoswitchOff: true), .init(recordingCall: true),
        ]
        #expect(MenuBarPolicy.isVisible(.always, quiet))
        #expect(!MenuBarPolicy.isVisible(.whenNeeded, quiet))
        #expect(!MenuBarPolicy.isVisible(.never, quiet))
        for news in cases {
            #expect(MenuBarPolicy.isVisible(.always, news))
            #expect(MenuBarPolicy.isVisible(.whenNeeded, news))
            #expect(!MenuBarPolicy.isVisible(.never, news))
        }
    }

    @Test func missingAccessKeepsTheItemOnScreen() {
        let lost = MenuBarSituation(accessMissing: true)
        #expect(lost.hasNews)
        for visibility in MenuBarVisibility.allCases {
            #expect(MenuBarPolicy.isVisible(visibility, lost))
        }
        #expect(!MenuBarPolicy.isVisible(.never, MenuBarSituation(paused: true)))
    }

    @Test func onlyTheMarkAndHidingDropTheLanguage() {
        for style in [MenuBarIconStyle.capsule, .letters, .system] {
            #expect(MenuBarPolicy.showsLanguage(style: style, visibility: .always))
            #expect(!MenuBarPolicy.showsLanguage(style: style, visibility: .whenNeeded))
            #expect(!MenuBarPolicy.showsLanguage(style: style, visibility: .never))
        }
        #expect(!MenuBarPolicy.showsLanguage(style: .mark, visibility: .always))
    }

    @Test func noticeFollowsTheSystemMenu() {
        #expect(MenuBarPolicy.notice(style: .capsule, visibility: .always, systemMenuVisible: true) == .shownTwice)
        #expect(MenuBarPolicy.notice(style: .letters, visibility: .always, systemMenuVisible: false) == nil)
        #expect(MenuBarPolicy.notice(style: .mark, visibility: .always, systemMenuVisible: true) == nil)
        #expect(MenuBarPolicy.notice(style: .mark, visibility: .always, systemMenuVisible: false) == .notShown)
        #expect(MenuBarPolicy.notice(style: .capsule, visibility: .never, systemMenuVisible: false) == .notShown)
        #expect(MenuBarPolicy.notice(style: .capsule, visibility: .whenNeeded, systemMenuVisible: false) == .notShown)
        #expect(MenuBarPolicy.notice(style: .capsule, visibility: .whenNeeded, systemMenuVisible: true) == nil)
        #expect(MenuBarPolicy.notice(style: .capsule, visibility: .always, systemMenuVisible: nil) == nil)
    }
}
