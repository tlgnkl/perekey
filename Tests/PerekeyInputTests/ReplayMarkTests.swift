// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import PerekeyCore
import Testing
@testable import PerekeyInput

/// Events are built and read here, never posted.
@Suite struct ReplayMarkTests {
    private func key(_ code: CGKeyCode, down: Bool, userData: Int64, flags: CGEventFlags = [.maskShift]) throws -> CGEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        source.userData = userData
        let event = try #require(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }

    private func mark(_ event: CGEvent) -> SyntheticMark? {
        SyntheticMark(userData: event.getIntegerValueField(.eventSourceUserData))
    }

    @Test func unmarkedEventIsMarkedInPlace() throws {
        let event = try key(9, down: true, userData: 0)
        let out = ReplayMark.marked(event)
        #expect(mark(out) == .replayed)
        #expect(out.getIntegerValueField(.keyboardEventKeycode) == 9)
        #expect(out.flags.contains(.maskShift))
    }

    @Test(arguments: [true, false]) func foreignMarkIsReplaced(down: Bool) throws {
        let event = try key(11, down: down, userData: 0x4245 << 48)
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0431])  // "б": no layout types it on key 11
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let out = ReplayMark.marked(event)
        #expect(mark(out) == .replayed)
        #expect(out.type == (down ? .keyDown : .keyUp))
        #expect(out.getIntegerValueField(.keyboardEventKeycode) == 11)
        #expect(out.flags.contains(.maskShift))
        #expect(out.getIntegerValueField(.keyboardEventAutorepeat) == 1)
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        out.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        #expect(length == 1 && units[0] == 0x0431)
    }

    @Test func foreignMarkOnFlagsChanged() throws {
        let source = try #require(CGEventSource(stateID: .privateState))
        source.userData = 0x4245 << 48
        let event = try #require(CGEvent(source: source))
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: 56)
        event.flags = [.maskShift]
        let out = ReplayMark.marked(event)
        #expect(mark(out) == .replayed)
        #expect(out.type == .flagsChanged)
        #expect(out.getIntegerValueField(.keyboardEventKeycode) == 56)
        #expect(out.flags.contains(.maskShift))
    }

    private let abc = LayoutMap(id: LayoutID(rawValue: "abc"), language: "en", table: [KeyStroke(11): "b", KeyStroke(11, .shift): "B"])
    private let russian = LayoutMap(id: LayoutID(rawValue: "ru"), language: "ru", table: [KeyStroke(11): "и", KeyStroke(11, .shift): "И"])

    private func text(_ event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }

    @Test func stringComputedForTheKeyIsNotCarried() throws {
        let event = try key(11, down: true, userData: 0x4245 << 48, flags: [])
        // The string of the layout at creation time: the layouts below type "b" on key 11 (as ABC does).
        // The system types "и" or "b" on key 11, never "ы": a carried string would show.
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x044B])
        let standIn = LayoutMap(id: LayoutID(rawValue: "x"), language: nil, table: [KeyStroke(11): "ы"])
        let out = try #require(ReplayMark.rebuilt(event, mark: SyntheticMark.replayed.userData, layouts: [abc, standIn, russian]))
        #expect(mark(out) == .replayed)
        #expect(text(out) != "ы")
    }

    @Test func stringSetByTheProgramIsCarried() throws {
        let event = try key(0, down: true, userData: 0x4245 << 48, flags: [])
        event.keyboardSetUnicodeString(stringLength: 2, unicodeString: [0x0436, 0x0451])
        let out = try #require(ReplayMark.rebuilt(event, mark: SyntheticMark.replayed.userData, layouts: [abc, russian]))
        #expect(mark(out) == .replayed)
        #expect(text(out) == "жё")
    }
}
