// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyEvalKit
import Testing

@Suite struct CaseFormatTests {
    @Test func everyFixtureLineSurvivesReadingAndWritingByteForByte() throws {
        let text = try String(contentsOfFile: Repo.fixture("cases.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        let items = try CaseCodec.read(text)
        #expect(items.count == lines.count)
        #expect(items.count >= 3)
        for (item, line) in zip(items, lines) {
            #expect(try CaseCodec.line(item) == line)
        }
        #expect(try CaseCodec.write(items) == text)
    }

    @Test(arguments: ["eval/cases/flow.basics.jsonl", "eval/cases/incidents.jsonl"])
    func casesWrittenByHandAreCanonicalAndPassTheCheck(file: String) throws {
        let text = try String(contentsOfFile: Repo.path(file), encoding: .utf8)
        let items = try CaseCodec.read(text)
        #expect(!items.isEmpty)
        #expect(try CaseCodec.write(items) == text)
        for item in items {
            #expect(CaseCheck.problems(item, layouts: Repo.library) == [], "\(item.id)")
            #expect(item.split == .dev, "cases written by hand are all dev")
            #expect(item.meta?["why"]?.string?.isEmpty == false || item.meta?["issue"] != nil, "\(item.id) says why")
        }
    }

    @Test func fixtureCasesPassTheCheck() throws {
        for item in try CaseCodec.read(file: Repo.fixture("cases.jsonl")) {
            #expect(CaseCheck.problems(item, layouts: Repo.library) == [], "\(item.id)")
        }
    }

    @Test func anUnknownStepIsAnError() throws {
        let line = try CaseCodec.line(Cases.make([.type("hello ", on: "ABC")], want: "hello"))
        let broken = line.replacingOccurrences(of: #"{"on":"ABC","type":"hello "}"#, with: #"{"jump":3}"#)
        #expect(broken != line)
        #expect(throws: (any Error).self) { try CaseCodec.decode(broken) }
    }

    @Test func anUnknownFieldOfAStepIsAnError() throws {
        let line = try CaseCodec.line(Cases.make([.type("hello ", on: "ABC")], want: "hello"))
        let broken = line.replacingOccurrences(of: #""type":"hello ""#, with: #""type":"hello ","times":2"#)
        #expect(throws: (any Error).self) { try CaseCodec.decode(broken) }
    }

    @Test func anotherVersionIsAnError() throws {
        let line = try CaseCodec.line(Cases.make([.type("hello ", on: "ABC")], want: "hello"))
        #expect(line.contains(#""v":1"#))
        #expect(throws: (any Error).self) { try CaseCodec.decode(line.replacingOccurrences(of: #""v":1"#, with: #""v":2"#)) }
    }

    @Test func anUnknownFieldOfTheCaseIsAnError() throws {
        let line = try CaseCodec.line(Cases.make([.type("hello ", on: "ABC")], want: "hello"))
        #expect(throws: (any Error).self) { try CaseCodec.decode(line.replacingOccurrences(of: #""v":1"#, with: #""v":1,"x":1"#)) }
    }

    @Test func theIDIsTheHashOfTheContent() throws {
        let item = Cases.make([.type("привет ", on: "Russian")], want: "привет")
        #expect(item.id.hasPrefix("test/clean.cold/"))
        #expect(item.id.count == "test/clean.cold/".count + 12)
        // The same content in another suite has the same hash.
        var other = item
        other.suite = "other"
        other.tokens = nil
        #expect(try other.computedID().suffix(12) == item.id.suffix(12))
        // Other content, another id.
        var changed = item
        changed.want = "привет!"
        #expect(try changed.computedID() != item.id)
        // An absent env and an empty one are the same content.
        var empty = item
        empty.env = Env()
        #expect(try empty.computedID() == item.id)
    }

    @Test func fnv1aMatchesTheReference() {
        // FNV-1a 64 of "" and "a" (the reference values of the algorithm).
        #expect(FNV1a.hash64("") == 0xCBF2_9CE4_8422_2325)
        #expect(FNV1a.hash64("a") == 0xAF63_DC4C_8601_EC8C)
    }

    @Test func theCheckFindsAWrongID() {
        var item = Cases.make([.type("hello ", on: "ABC")], want: "hello")
        item.id = "test/clean.cold/000000000000"
        #expect(CaseCheck.problems(item, layouts: Repo.library).contains { $0.contains("not the hash") })
    }

    @Test func theCheckFindsACharacterTheLayoutDoesNotType() {
        let item = Cases.make([.type("привет ", on: "ABC")], want: "привет")
        #expect(CaseCheck.problems(item, layouts: Repo.library).contains { $0.contains("does not type") })
    }

    @Test func theCheckFindsAnOptionCharacter() {
        // "©" is ⌥G in ABC: format v1 types nothing with ⌥.
        let item = Cases.make([.type("© ", on: "ABC")], want: "©", tokens: [TokenSpec(t: "©", lang: "-")])
        #expect(CaseCheck.problems(item, layouts: Repo.library).contains { $0.contains("does not type") })
    }

    @Test func theCheckFindsTokensThatDoNotMatchTheSteps() {
        let item = Cases.make([.type("привет мир ", on: "Russian")], want: "привет мир",
                              tokens: [TokenSpec(t: "привет", lang: "ru"), TokenSpec(t: "мор", lang: "ru")])
        let problems = CaseCheck.problems(item, layouts: Repo.library)
        #expect(problems.contains { $0.contains("the steps give") })
    }

    @Test func aTypoTokenMustDifferFromWhatIsTyped() {
        let item = Cases.make([.type("привет ", on: "Russian")], want: "привет",
                              tokens: [TokenSpec(t: "привет", lang: "ru", err: .typo)])
        #expect(CaseCheck.problems(item, layouts: Repo.library).contains { $0.contains("nothing differs") })
    }

    @Test func theCheckFindsAnUnknownLayoutAndAStartOutsideTheLayouts() {
        let unknown = Cases.make([.type("hello ", on: "ABC")], want: "hello", layouts: ["ABC", "Klingon"])
        #expect(CaseCheck.problems(unknown, layouts: Repo.library).contains { $0.contains("unknown layout Klingon") })
        let start = Cases.make([.type("hello ", on: "ABC")], want: "hello", start: "Ukrainian")
        #expect(CaseCheck.problems(start, layouts: Repo.library).contains { $0.contains("start Ukrainian") })
    }

    @Test func theTargetTextFollowsEditingKeys() {
        let item = Cases.make([.type("helo", on: "ABC"), .key(.backspace, n: 1, mods: nil), .type("lo there ", on: "ABC"),
                               .key(.left, n: 3, mods: nil), .select(2), .type("x", on: "ABC")],
                              want: "hello txre", scoring: .case)
        #expect(TargetText.of(item).full == "hello txre ")
    }

    @Test func warmupTokensAreNotMeasured() {
        let item = Cases.make([.type("привет ", on: "Russian")], want: "I will привет",
                              warmup: [.type("I will ", on: "ABC")])
        #expect(item.warmupTokenCount == 2)
        #expect(item.measuredWant == ["привет"])
        #expect(CaseCheck.problems(item, layouts: Repo.library) == [])
    }
}
