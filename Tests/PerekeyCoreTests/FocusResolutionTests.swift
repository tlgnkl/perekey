// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

private let orca = "com.stablyai.orca"

/// The first word after an app switch: the focus is unknown until
/// accessibility names the element, and an Electron app may report the same
/// element again in the middle of a word ("jrtq vj;tim" came out "jrtq можешь").
@Suite struct FocusResolutionTests {
    /// The app the user switches to, before its focused element is known.
    private func switchedToOrca() -> Desk {
        var desk = Desk()
        desk.send(.focusChanged(.unknown(bundleID: orca)))
        return desk
    }

    @Test func wordStartedBeforeTheFocusIsKnownSwitchesInside() throws {
        var desk = switchedToOrca()
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        desk.type("b")
        #expect(desk.text == "при")
        desk.type("dtn ")
        #expect(desk.text == "привет ")
        #expect(try #require(desk.corrections.first).original == "ghbdtn")
    }

    @Test func wordTypedBeforeTheFocusIsKnownIsJudgedAtItsEnd() {
        var desk = switchedToOrca()
        desk.type("[jhjij")
        #expect(desk.text == "[jhjij")
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        desk.type(" ")
        #expect(desk.text == "хорошо ")
    }

    @Test func wordEndedWhileTheFocusIsUnknownStays() {
        var desk = switchedToOrca()
        desk.type("ghbdtn ")
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        #expect(desk.text == "ghbdtn ")
        desk.type("[jhjij ")
        #expect(desk.text == "ghbdtn хорошо ")
    }

    @Test func sameElementReportedAgainKeepsTheWord() {
        var desk = Desk(focus: Focus(bundleID: orca))
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        desk.type("bdtn ")
        #expect(desk.text == "привет ")
    }

    @Test func anotherElementDropsTheWord() {
        // Another field of the same kind is still a new place.
        var desk = Desk(focus: Focus(bundleID: orca))
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca)))
        #expect(desk.machine.buffer.isEmpty)
        desk = switchedToOrca()
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca), .moved))
        #expect(desk.machine.buffer.isEmpty)
    }

    @Test func resolvedInAnotherAppIsAMove() {
        var desk = Desk()
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        #expect(desk.machine.buffer.isEmpty)
    }

    @Test func clickWhileTheFocusIsUnknownStillClears() {
        var desk = switchedToOrca()
        desk.type("gh")
        desk.send(.click(time: desk.time))
        desk.send(.focusChanged(Focus(bundleID: orca), .resolved))
        #expect(desk.machine.buffer.isEmpty)
    }

    @Test func passwordFieldFoundLateKeepsItQuiet() {
        var desk = switchedToOrca()
        desk.type("gh")
        desk.send(.focusChanged(Focus(bundleID: orca, isSecureField: true), .resolved))
        desk.type("bdtn ")
        #expect(desk.text == "ghbdtn ")
    }
}
