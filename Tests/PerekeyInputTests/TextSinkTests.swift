// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import PerekeyCore
import Testing
@testable import PerekeyInput

@Suite struct TextSinkTests {
    private let retype = Retype(
        deleteCount: 2,
        keys: [
            Retype.Key(stroke: KeyStroke(35, .shift), text: "З"),
            Retype.Key(stroke: KeyStroke(31), text: "щ"),
        ],
        target: "com.apple.keylayout.Russian", expected: "Po", seq: 7,
        origin: .manual(.convertLastWord)
    )

    private func text(of event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: 20)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }

    @Test func backspacesThenKeysEachWithKeyUp() {
        let events = TextSink.events(for: retype, source: nil)
        #expect(events.count == 8)
        #expect(events.map { UInt16($0.getIntegerValueField(.keyboardEventKeycode)) } == [51, 51, 51, 51, 35, 35, 31, 31])
        #expect(events.map { $0.type } == [.keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp, .keyDown, .keyUp])
        #expect(text(of: events[4]) == "З")
        #expect(text(of: events[6]) == "щ")
    }

    @Test func flagsAreShiftAndCapsOnly() {
        let events = TextSink.events(for: retype, source: nil)
        #expect(events[0].flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl]).isEmpty)
        #expect(events[4].flags.contains(.maskShift))
        #expect(!events[6].flags.contains(.maskShift))
    }

    @Test func onlyTheLastEventIsMarkedLast() {
        let marks = TextSink.events(for: retype, source: nil)
            .map { SyntheticMark(userData: $0.getIntegerValueField(.eventSourceUserData)) }
        #expect(marks.dropLast().allSatisfy { $0 == .own(seq: 7, last: false) })
        #expect(marks.last == .own(seq: 7, last: true))
    }
}
