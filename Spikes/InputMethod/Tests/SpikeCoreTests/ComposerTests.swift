// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import SpikeCore
import Testing

/// Layouts dumped from macOS by `perekey-layout-dump`; the app's own fixtures.
enum Fixture {
    static let abc = layout("ABC")
    static let russian = layout("Russian")

    static func layout(_ name: String) -> LayoutMap {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SpikeCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // InputMethod
            .deletingLastPathComponent() // Spikes
            .deletingLastPathComponent() // repository
            .appendingPathComponent("Tests/PerekeyCoreTests/Fixtures/\(name).json")
        return try! JSONDecoder().decode(LayoutMap.self, from: Data(contentsOf: url))
    }
}

extension LayoutMap {
    func strokes(_ text: String) -> [KeyStroke] {
        text.map { stroke(for: $0)! }
    }
}

/// A word list decider: switch when the other reading is a known word and the typed one is not.
func dictionaryDecider(_ words: Set<String>) -> Composer.Decide {
    { strokes, typed, other in
        let typedText = strokes.compactMap { typed.text(for: $0) }.joined()
        let otherText = strokes.compactMap { other.text(for: $0) }.joined()
        return words.contains(otherText.lowercased()) && !words.contains(typedText.lowercased())
    }
}

let words: Set<String> = ["привет", "мир", "будет", "когда", "работа", "hello", "world", "when", "work", "good"]

func composer(_ strategy: Strategy, current: LayoutMap = Fixture.abc) -> Composer {
    Composer(strategy: strategy, latin: Fixture.abc, cyrillic: Fixture.russian, current: current.id,
             decide: dictionaryDecider(words))
}

func type(_ text: String, on layout: LayoutMap, into composer: Composer, client: BufferClient) {
    for stroke in layout.strokes(text) {
        _ = composer.key(stroke, command: false, client: client)
    }
}

@Suite struct MarkedTextStrategy {
    @Test func theWordIsMarkedWhileTypedAndCommittedSwitchedAtTheSpace() {
        let client = BufferClient()
        let composer = composer(.marked)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "")
        #expect(client.marked == "ghbdtn")
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
        #expect(client.marked == "")
        #expect(composer.current == Fixture.russian.id)
    }

    @Test func backspaceShortensTheMarkedWord() {
        let client = BufferClient()
        let composer = composer(.marked)
        type("ghbdtnn", on: Fixture.abc, into: composer, client: client)
        #expect(composer.key(KeyStroke(KeyCode.delete), command: false, client: client))
        #expect(client.marked == "ghbdtn")
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
    }

    @Test func aCommandKeyCommitsTheWordAsTypedAndPassesThrough() {
        let client = BufferClient()
        let composer = composer(.marked)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(!composer.key(KeyStroke(0), command: true, client: client))
        #expect(client.committed == "ghbdtn")
        #expect(client.marked == "")
    }

    @Test func returnCommitsTheJudgedWordAndPassesThrough() {
        let client = BufferClient()
        let composer = composer(.marked)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(!composer.key(KeyStroke(KeyCode.return), command: false, client: client))
        #expect(client.committed == "привет")
    }
}

@Suite struct ReplacementStrategy {
    @Test func lettersAreCommittedAtOnceAndTheWordIsReplacedAtTheSpace() {
        let client = BufferClient()
        let composer = composer(.replace)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "ghbdtn")
        #expect(client.marked == "")
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
        #expect(composer.stats.replaced == 1)
        #expect(client.replacements == 1)
    }

    @Test func theWordIsReplacedInTheMiddleOfTheText() {
        let client = BufferClient(committed: "ab", selection: 1)
        let composer = composer(.replace)
        type("ghbdtn ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "aпривет b")
    }

    @Test func textChangedByTheAppIsNotReplaced() {
        let client = BufferClient()
        let composer = composer(.replace)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        client.committed = "ghbdtM" // an autocorrection or another writer
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "ghbdtM ")
        #expect(composer.stats.refused == 1)
    }

    @Test func aClientWithoutDocumentAccessGetsMarkedText() {
        let client = BufferClient(documentAccess: false)
        let composer = composer(.replace)
        type("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(client.marked == "ghbdtn")
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
        #expect(composer.stats.fellBack == 1)
    }

    @Test func aClientThatIgnoresTheRangeIsCaughtAndLeftToMarkedText() {
        let client = BufferClient(ignoresReplacement: true)
        let composer = composer(.replace)
        type("ghbdtn ", on: Fixture.abc, into: composer, client: client)
        // The first replacement lands at the caret: the damage the check reports.
        #expect(client.committed == "ghbdtnпривет ")
        #expect(composer.stats.broken == 1)
        type("мир ", on: Fixture.russian, into: composer, client: client)
        #expect(client.committed == "ghbdtnпривет мир ")
        #expect(composer.stats.fellBack == 1)
    }

    @Test func backspacePassesThroughAndTheWordStillReplaces() {
        let client = BufferClient()
        let composer = composer(.replace)
        type("ghbdtnn", on: Fixture.abc, into: composer, client: client)
        #expect(!composer.key(KeyStroke(KeyCode.delete), command: false, client: client))
        client.deleteBackward() // what the app does with the passed key
        type(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
    }

    @Test func optionTapRetypesTheLastWord() {
        let client = BufferClient()
        let composer = Composer(strategy: .replace, latin: Fixture.abc, cyrillic: Fixture.russian,
                                current: Fixture.abc.id, decide: { _, _, _ in false })
        type("ghbdtn ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "ghbdtn ")
        #expect(composer.optionTap(client: client))
        #expect(client.committed == "привет ")
        #expect(composer.current == Fixture.russian.id)
        #expect(composer.stats.manual == 1)
    }

    @Test func shiftKeepsCapitals() {
        let client = BufferClient()
        let composer = composer(.replace)
        type("Ghbdtn ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "Привет ")
    }
}

/// Types like an app with the input method in front: a key the method passes on
/// types its own character in the method's layout.
func typeThrough(_ text: String, on layout: LayoutMap, into composer: Composer, client: BufferClient) {
    for stroke in layout.strokes(text) {
        let typing = composer.layout
        if !composer.key(stroke, command: false, client: client) {
            if stroke.keyCode == KeyCode.delete {
                client.deleteBackward()
            } else if let character = typing.text(for: stroke) {
                client.insert(character, replacing: nil)
            }
        }
    }
}

@Suite struct TransparentStrategy {
    @Test func theAppTypesTheLettersAndTheWordIsReplacedAtTheSpace() {
        let client = BufferClient()
        let composer = composer(.transparent)
        typeThrough("ghbdtn", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "ghbdtn")
        #expect(client.replacements == 0)
        typeThrough(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
        #expect(composer.stats.replaced == 1)
        #expect(composer.current == Fixture.russian.id)
    }

    @Test func noLetterIsHandledByTheInputMethod() {
        let client = BufferClient()
        let composer = composer(.transparent)
        for stroke in Fixture.abc.strokes("ghbdtn vbh ") {
            #expect(!composer.key(stroke, command: false, client: client))
            if let character = composer.layout.text(for: stroke) { client.insert(character, replacing: nil) }
        }
    }

    @Test func backspaceIsTheApps() {
        let client = BufferClient()
        let composer = composer(.transparent)
        typeThrough("ghbdtnn", on: Fixture.abc, into: composer, client: client)
        #expect(!composer.key(KeyStroke(KeyCode.delete), command: false, client: client))
        client.deleteBackward()
        typeThrough(" ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "привет ")
    }

    @Test func aClientWithoutDocumentAccessKeepsTheWordAsTyped() {
        let client = BufferClient(documentAccess: false)
        let composer = composer(.transparent)
        typeThrough("ghbdtn ", on: Fixture.abc, into: composer, client: client)
        #expect(client.committed == "ghbdtn ")
        #expect(composer.stats.refused == 1)
    }
}

/// The plan's "1000 words": no lost, doubled or swapped letter in either strategy.
@Suite struct ThousandWords {
    static let russianWords = ["привет", "мир", "будет", "когда", "работа"]
    static let englishWords = ["hello", "world", "when", "work", "good"]

    /// Words and the layout each is meant in, from a fixed seed.
    static func script() -> [(word: String, layout: LayoutMap)] {
        var generator = SplitMix(seed: 42)
        return (0..<1000).map { _ in
            let russian = generator.next() % 2 == 0
            let list = russian ? russianWords : englishWords
            let word = list[Int(generator.next() % UInt64(list.count))]
            return (word, russian ? Fixture.russian : Fixture.abc)
        }
    }

    @Test(arguments: Strategy.allCases)
    func everyWordArrivesInItsLayout(strategy: Strategy) {
        let client = BufferClient()
        let composer = composer(strategy)
        var expected = ""
        for (word, layout) in Self.script() {
            if strategy == .transparent {
                typeThrough(word + " ", on: layout, into: composer, client: client)
            } else {
                type(word + " ", on: layout, into: composer, client: client)
            }
            expected += word + " "
        }
        #expect(client.committed == expected)
        #expect(client.marked == "")
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
