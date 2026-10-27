// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct MenuLayoutTests {
    @Test func defaultsShowTheUsualBlocksAndHideTheRest() {
        let layout = MenuLayout()
        #expect(layout.isDefault)
        for block in MenuBlock.allCases {
            #expect(layout.shows(block) == block.shownByDefault)
        }
        #expect(!layout.shows(.launchAtLogin) && !layout.shows(.howTo) && !layout.shows(.layoutsList))
        #expect(layout.shows(.modeCard) && layout.shows(.pause) && layout.shows(.about) && layout.shows(.statistics))
        #expect(layout.rows(of: .recentCorrections) == 5)
        #expect(layout.rows(of: .recentDictations) == 3)
    }

    @Test func onlyTheDifferencesAreKept() {
        var layout = MenuLayout()
        layout.set(.about, shown: false)
        layout.set(.howTo, shown: true)
        layout.setRows(3, of: .recentCorrections)
        #expect(!layout.shows(.about) && layout.shows(.howTo))
        #expect(layout.rows(of: .recentCorrections) == 3)
        #expect(layout.hidden == [.about] && layout.shown == [.howTo])
        // Back to the default: nothing stays.
        layout.set(.about, shown: true)
        layout.set(.howTo, shown: false)
        layout.setRows(5, of: .recentCorrections)
        #expect(layout.isDefault)
    }

    @Test func zeroRowsHideAListAndShowingBringsTheDefaultBack() {
        var layout = MenuLayout()
        layout.setRows(0, of: .recentDictations)
        #expect(!layout.shows(.recentDictations))
        #expect(layout.rows(of: .recentDictations) == 0)
        layout.set(.recentDictations, shown: true)
        #expect(layout.rows(of: .recentDictations) == 3)
        layout.set(.recentCorrections, shown: false)
        #expect(layout.rows(of: .recentCorrections) == 0)
        #expect(!layout.isDefault)
    }

    @Test func rowsOutsideTheChoicesAreIgnored() {
        var layout = MenuLayout()
        layout.setRows(4, of: .recentCorrections)
        layout.setRows(-1, of: .recentDictations)
        #expect(layout.isDefault)
    }

    @Test func resetReturnsEveryDefault() {
        var layout = MenuLayout()
        layout.set(.pause, shown: false)
        layout.set(.layoutsList, shown: true)
        layout.setRows(0, of: .recentCorrections)
        layout.reset()
        #expect(layout.isDefault)
        #expect(layout == MenuLayout())
    }

    @Test func oldSettingsFileHasTheDefaultMenu() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.menu == MenuLayout())
        #expect(old.menu.isDefault)
    }

    @Test func defaultMenuWritesNothingExtra() throws {
        let data = try JSONEncoder().encode(MenuLayout())
        #expect(String(decoding: data, as: UTF8.self) == "{}")
    }

    @Test func roundTripKeepsTheChoice() throws {
        var settings = AppSettings()
        settings.menu.set(.about, shown: false)
        settings.menu.set(.launchAtLogin, shown: true)
        settings.menu.setRows(0, of: .recentCorrections)
        settings.menu.setRows(5, of: .recentDictations)
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
        #expect(!back.menu.shows(.about) && back.menu.shows(.launchAtLogin))
        #expect(back.menu.rows(of: .recentCorrections) == 0 && back.menu.rows(of: .recentDictations) == 5)
    }

    @Test func aBlockOfALaterVersionAppearsOnItsOwn() throws {
        // A file that names a block this version lacks, and one that never hid anything.
        let json = #"{"menu":{"hidden":["about","teleport"],"shown":["howTo","teleport"],"correctionRows":4}}"#
        let layout = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).menu
        #expect(layout.hidden == [.about] && layout.shown == [.howTo])
        #expect(layout.rows(of: .recentCorrections) == 5)
        // Every block that is not in the file has its default.
        for block in MenuBlock.allCases where block != .about && block != .howTo {
            #expect(layout.shows(block) == block.shownByDefault)
        }
    }

    @Test func aWrongKindOfBlockInTheFileIsDropped() throws {
        // "pause" is in by default, so it cannot be in `shown`; the file is hand-made.
        let json = #"{"menu":{"shown":["pause"],"hidden":["layoutsList","recentDictations"]}}"#
        let layout = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).menu
        #expect(layout.isDefault)
    }

    @Test func aBrokenMenuFieldFallsBackToTheDefault() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"menu":"all","autoswitch":false}"#.utf8))
        #expect(settings.menu.isDefault)
        #expect(!settings.autoswitch)
    }

    @Test func roomIsTheScreenUnderTheItemLessTheMargins() {
        #expect(MenuRoom.budget(itemBottom: 900, visibleBottom: 0) == 900 - 4 - 8)
        #expect(MenuRoom.budget(itemBottom: 10, visibleBottom: 100) == 0)
    }
}
