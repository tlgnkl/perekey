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

    private func text(_ entries: [WordBuffer.Entry]?) -> String? {
        entries.map { Fixture.abc.type($0.map(\.stroke)) }
    }

    @Test func keepsWordsBeforeForAPhrase() {
        let buffer = typed("a  bc d ")
        #expect(text(buffer.entries) == "d ")
        #expect(buffer.historyCount == 2)
        #expect(text(buffer.phrase(words: 1)) == "d ")
        #expect(text(buffer.phrase(words: 2)) == "bc d ")
        #expect(text(buffer.phrase(words: 3)) == "a  bc d ")
        #expect(buffer.phrase(words: 4) == nil)
    }

    @Test func historyKeepsTheLastWords() {
        for count in [12, 30] {
            // The last word has count % 3 + 1 letters: 12 ends on "x", 30 too.
            let buffer = typed((1...count).map { String(repeating: "x", count: $0 % 3 + 1) }.joined(separator: " "))
            #expect(text(buffer.phrase(words: WordBuffer.historyWords + 1)) == "xxx x xx xxx x xx xxx x")
            #expect(buffer.phrase(words: WordBuffer.historyWords + 2) == nil)
        }
    }

    @Test func historyEndsWhereTheBufferLosesTrack() {
        var buffer = typed("ab cd")
        buffer.deleteBackward()
        buffer.deleteBackward()
        #expect(buffer.historyCount == 1, "deleting the current word keeps the words before")
        buffer.deleteBackward()
        #expect(buffer.historyCount == 0, "deleting into them does not")
        buffer = typed("ab cd")
        buffer.clear()
        #expect(buffer.phrase(words: 1) == nil && buffer.historyCount == 0)
        buffer = typed("ab cd")
        buffer.abandonWord()
        #expect(buffer.historyCount == 0)
    }

    @Test func relabelsAPhraseAndReplacesAWord() {
        var buffer = typed("ab cd ")
        let russian = buffer.phrase(words: 2)!.map { WordBuffer.Entry($0.stroke, in: Fixture.russian.id) }
        buffer.relabelPhrase(russian)
        #expect(buffer.phrase(words: 2) == russian)

        buffer = typed("ab")
        buffer.replaceWord(Fixture.abc.strokes("xyz"), in: Fixture.russian.id)
        #expect(Fixture.abc.type(buffer.entries.map(\.stroke)) == "xyz")
        #expect(buffer.wordLayout == Fixture.russian.id)
    }
}
