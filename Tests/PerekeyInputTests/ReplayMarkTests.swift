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
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0431])
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
}
