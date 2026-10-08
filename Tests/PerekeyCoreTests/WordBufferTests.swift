// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct WordBufferTests {
    private let en = Fixture.abc.id

    private func typed(_ text: String) -> WordBuffer {
        var buffer = WordBuffer()
        for stroke in Fixture.abc.strokes(text) { buffer.type(stroke, in: en) }
        return buffer
    }

    @Test func keepsSpacesAfterWord() {
        #expect(typed("ghbdtn ").entries.count == 7)
    }

    @Test func nextWordStartsOver() {
        let buffer = typed("ghbdtn vbh")
        #expect(Fixture.abc.type(buffer.entries.map(\.stroke)) == "vbh")
    }

    @Test func leadingSpacesAreIgnored() {
        #expect(typed("  ").isEmpty)
    }

    @Test func backspaceRemovesLastKey() {
        var buffer = typed("ghbdtnn")
        buffer.deleteBackward()
        #expect(Fixture.abc.type(buffer.entries.map(\.stroke)) == "ghbdtn")
    }

    @Test func overflowGivesUpUntilSpace() {
        var buffer = typed(String(repeating: "a", count: WordBuffer.capacity + 1))
        #expect(buffer.isEmpty)
        for stroke in Fixture.abc.strokes("bc") { buffer.type(stroke, in: en) }
        #expect(buffer.isEmpty)
        for stroke in Fixture.abc.strokes(" ok") { buffer.type(stroke, in: en) }
        #expect(Fixture.abc.type(buffer.entries.map(\.stroke)) == "ok")
    }

    @Test func wordLayoutSkipsSpaces() {
        var buffer = typed("ghbdtn ")
        buffer.relabel(to: Fixture.russian.id)
        #expect(buffer.wordLayout == Fixture.russian.id)
    }
}
