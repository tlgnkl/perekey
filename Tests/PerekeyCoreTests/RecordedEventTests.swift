// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// The session format (docs/classifier.md, «Замер на живых сессиях»): every
/// event the machine handles is written as a `RecordedEvent` and read back
/// as the same event.
@Suite struct RecordedEventTests {
    /// One event of every case. A case added to `InputEvent` fails to compile
    /// in `name(of:)` until it is listed here and recorded.
    static let events: [InputEvent] = [
        .key(KeyEvent(.down, keyCode: 5, flags: Keyboard.leftShift, isRepeat: true, origin: .user), time: 1.25),
        .key(KeyEvent(.up, keyCode: 5, origin: .own(seq: 7, last: true)), time: 1.5),
        .key(KeyEvent(.down, keyCode: 49, origin: .replayed), time: 1.75),
        .flagsChanged(keyCode: 58, flags: Keyboard.leftOption, origin: .user, time: 2,
                      location: PointerLocation(x: 10.5, y: -3)),
        .flagsChanged(keyCode: 56, flags: 0, origin: .own(seq: 3, last: false), time: 2.5),
        .click(time: 3, onHint: true),
        .scroll(time: 3.5),
        .focusChanged(Focus(bundleID: "com.apple.TextEdit", isSecureField: true), .resolved),
        .focusChanged(.unknown(bundleID: nil), .moved),
        .layoutChanged(Fixture.russian.id),
        .layoutsChanged([Fixture.abc, Fixture.russian]),
        .secureInputChanged(true),
        .settingsChanged(Settings(autoswitch: false, learnFromUndos: false)),
        .retypePosted(seq: 9, time: 4),
        .retypeCancelled(seq: 10),
        .inputLost,
        .dictationTyping(true),
        .deadline(time: 5.125),
        .appModeChanged(.manualOnly),
        .undoLastCorrection(seq: 11, time: 6),
        .languageContextChanged(LanguageContext(app: "com.tinyspeck.slackmacgap", site: "example.org",
                                                prior: LanguagePrior(counts: ["ru": 120, "en": 30]),
                                                generation: 4)),
        .personalLexiconChanged(PersonalLexicon(key: PersonalKey(k0: 0x0706_0504_0302_0100, k1: 0xF0E_0D0C_0B0A_0908),
                                                words: [3, 0xFFFF_FFFF_FFFF_FFFF, 1], starts: [2], generation: 5)),
        .personalLexiconChanged(.off),
        .voiceHoldLost,
        .voiceSession(true),
    ]

    /// The case of an event, without `default`: the compiler names a new one.
    static func name(of event: InputEvent) -> String {
        switch event {
        case .key: "key"
        case .flagsChanged: "flagsChanged"
        case .click: "click"
        case .scroll: "scroll"
        case .focusChanged: "focusChanged"
        case .layoutChanged: "layoutChanged"
        case .layoutsChanged: "layoutsChanged"
        case .secureInputChanged: "secureInputChanged"
        case .settingsChanged: "settingsChanged"
        case .retypePosted: "retypePosted"
        case .retypeCancelled: "retypeCancelled"
        case .selectionRead: "selectionRead"
        case .inputLost: "inputLost"
        case .dictationTyping: "dictationTyping"
        case .deadline: "deadline"
        case .appModeChanged: "appModeChanged"
        case .classifierChanged: "classifierChanged"
        case .undoLastCorrection: "undoLastCorrection"
        case .languageContextChanged: "languageContextChanged"
        case .personalLexiconChanged: "personalLexiconChanged"
        case .voiceHoldLost: "voiceHoldLost"
        case .voiceSession: "voiceSession"
        case .personalRoomReturned: "personalRoomReturned"
        }
    }

    static func roundTrip(_ recorded: RecordedEvent) throws -> RecordedEvent {
        try JSONDecoder().decode(RecordedEvent.self, from: JSONEncoder().encode(recorded))
    }

    static let fixtureLanguages = ModelFixture.model.languages.map(\.code)

    static func classifier(_ spec: ClassifierSpec) -> Classifier? {
        Classifier(model: ModelFixture.model, options: spec.options)
    }

    @Test func everyCaseIsSampled() {
        let sampled = Set(Self.events.map(Self.name(of:)))
        let all: Set = [
            "key", "flagsChanged", "click", "scroll", "focusChanged", "layoutChanged", "layoutsChanged",
            "secureInputChanged", "settingsChanged", "retypePosted", "retypeCancelled", "selectionRead", "inputLost",
            "dictationTyping", "deadline", "appModeChanged", "classifierChanged", "undoLastCorrection",
            "languageContextChanged", "personalLexiconChanged", "voiceHoldLost", "voiceSession",
        ]
        // The two cases with their own rules have tests of their own below.
        #expect(sampled == all.subtracting(["selectionRead", "classifierChanged"]))
        // The buffer that moves memory is no part of a session.
        #expect(RecordedEvent(.personalRoomReturned(PersonalRoom())) == nil)
    }

    @Test(arguments: RecordedEventTests.events.indices)
    func eventSurvivesTheRecording(index: Int) throws {
        let event = Self.events[index]
        let recorded = try #require(RecordedEvent(event))
        let read = try Self.roundTrip(recorded)
        #expect(read == recorded)
        let replayed = read.inputEvent(classifier: Self.classifier)
        #expect(Self.name(of: replayed) == Self.name(of: event))
        #expect(try #require(RecordedEvent(replayed)) == recorded)
    }

    @Test func selectionIsRecordedAsItsLengthOnly() throws {
        let recorded = try #require(RecordedEvent(.selectionRead(seq: 4, text: "привет, мир", viaAccessibility: true)))
        #expect(recorded == .selectionRead(seq: 4, text: "xxxxxxxxxxx", viaAccessibility: true))
        let json = try #require(String(data: JSONEncoder().encode(recorded), encoding: .utf8))
        #expect(!json.contains("привет") && !json.contains("мир"))
        guard case let .selectionRead(seq, text, viaAccessibility) = recorded.inputEvent(classifier: Self.classifier)
        else { Issue.record("not a selection"); return }
        #expect(seq == 4 && text == "xxxxxxxxxxx" && viaAccessibility)
    }

    @Test func classifierIsRecordedAsItsLanguagesAndOptions() throws {
        var options = Classifier.Options()
        options.threshold = 12.5
        options.shortWordRank = 150
        let recorded = try #require(RecordedEvent(.classifierChanged(Classifier(model: ModelFixture.model, options: options))))
        #expect(recorded == .classifier(ClassifierSpec(languages: Self.fixtureLanguages, options: options)))
        let read = try Self.roundTrip(recorded)
        #expect(read == recorded)
        var asked: [ClassifierSpec] = []
        guard case let .classifierChanged(classifier?) = read.inputEvent(classifier: { spec in
            asked.append(spec)
            return Self.classifier(spec)
        }) else { Issue.record("no classifier"); return }
        #expect(classifier.options == options)
        #expect(asked == [ClassifierSpec(languages: Self.fixtureLanguages, options: options)])
    }

    @Test func noClassifierIsRecordedAsSuch() throws {
        let recorded = try #require(RecordedEvent(.classifierChanged(nil)))
        #expect(recorded == .noClassifier)
        #expect(try Self.roundTrip(recorded) == .noClassifier)
        guard case .classifierChanged(nil) = recorded.inputEvent(classifier: Self.classifier) else {
            Issue.record("a classifier appeared")
            return
        }
    }

    @Test func optionsReadWithDefaultsForMissingKeys() throws {
        let options = try JSONDecoder().decode(Classifier.Options.self, from: Data(#"{"threshold": 14}"#.utf8))
        var expected = Classifier.Options()
        expected.threshold = 14
        #expect(options == expected)
        var all = Classifier.Options()
        all.contextDecay = 0.5
        all.knownRank = 90
        // Written only when on (`withTheWordContextOffTheOptionsAreCodedAsOnMain`).
        all.wordContextLimit = 4
        #expect(try JSONDecoder().decode(Classifier.Options.self, from: JSONEncoder().encode(all)) == all)
        // An option added to `Classifier.Options` needs its key in the coding too.
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(all)) as? [String: Any]
        #expect(keys?.count == Mirror(reflecting: all).children.count)
    }

    @Test func outputDigestKeepsTheFactsOfEachEffect() throws {
        var desk = Desk()
        desk.tape = []
        desk.type("[jhjij ")
        desk.press(KeyCode.delete)
        desk.type(" ")
        let digests = try #require(desk.tape).map(\.output)
        let effects = digests.flatMap(\.effects)
        #expect(effects.contains(.selectLayout(Fixture.russian.id)))
        #expect(effects.contains { if case let .retype(retype) = $0 { retype.origin == "automatic.layout" && retype.keys == 6 } else { false } })
        #expect(effects.contains { if case let .corrected(correction) = $0 { correction.original == "[jhjij" && correction.replacement == "хорошо" && correction.kind == "layout" } else { false } })
        #expect(effects.contains { if case let .undoSettled(report) = $0 { report.channel == .backspace && report.followUp == .continued } else { false } })
        #expect(digests.contains { $0.disposition == .hold })
        for digest in digests {
            #expect(try JSONDecoder().decode(OutputDigest.self, from: JSONEncoder().encode(digest)) == digest)
        }
    }

    @Test func undoReportDigestHoldsNoWord() throws {
        var desk = Desk()
        desk.tape = []
        desk.type("[jhjij ")
        desk.send(.undoLastCorrection(seq: try #require(desk.corrections.first).seq, time: desk.time))
        desk.settle()
        let tape = try #require(desk.tape)
        let settled = tape.flatMap(\.output.effects).filter { if case .undoSettled = $0 { true } else { false } }
        #expect(settled.count == 1)
        let json = try #require(String(data: JSONEncoder().encode(settled), encoding: .utf8))
        #expect(!json.contains("jhjij"))
    }
}

/// `Classifier.Options` is coded by hand: a key per stored property.
@Suite struct ClassifierOptionsCodingTests {
    @Test func theKeysAreTheStoredProperties() {
        let stored = Mirror(reflecting: Classifier.Options()).children.compactMap(\.label)
        #expect(stored.count == Set(stored).count)
        #expect(Set(stored) == Set(Classifier.Options.codingKeyNames), "a property added without its key")
        #expect(Classifier.Options.codingKeyNames.count == Set(Classifier.Options.codingKeyNames).count)
    }

    @Test func everyPropertySurvivesJson() throws {
        var options = Classifier.Options()
        options.threshold += 1
        options.readingMargin += 1
        options.unknownWordExtra += 1
        options.noiseCost += 1
        options.unknownNoiseCost += 1
        options.openerBonus += 1
        options.dictionaryBonus += 1
        options.rankBonus += 1
        options.knownRank += 1
        options.mixedCaseRank += 1
        options.contextBonus += 1
        options.contextDecay += 1
        options.priorLimit += 1
        options.priorScale += 1
        options.shortWordRank += 1
        options.personalRank += 1
        options.personalNoiseCost += 1
        options.wordContextLimit += 1
        let read = try JSONDecoder().decode(Classifier.Options.self, from: JSONEncoder().encode(options))
        #expect(read == options)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any]
        #expect(Set(json?.keys ?? [:].keys) == Set(Classifier.Options.codingKeyNames))
    }

    /// The keys `Classifier.Options` wrote on origin/main, before the word context.
    static let keysOnMain: Set<String> = [
        "threshold", "readingMargin", "unknownWordExtra", "noiseCost", "unknownNoiseCost", "openerBonus",
        "dictionaryBonus", "rankBonus", "knownRank", "mixedCaseRank", "contextBonus", "contextDecay", "priorLimit",
        "priorScale", "shortWordRank", "personalRank", "personalNoiseCost",
    ]

    @Test func withTheWordContextOffTheOptionsAreCodedAsOnMain() throws {
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Classifier.Options()))
            as? [String: Any])
        #expect(Set(json.keys) == Self.keysOnMain)
        // Read back, the missing key is the default, off.
        let read = try JSONDecoder().decode(Classifier.Options.self, from: JSONEncoder().encode(Classifier.Options()))
        #expect(read == Classifier.Options())
    }

    @Test func aLimitAboveZeroIsWritten() throws {
        var options = Classifier.Options()
        options.wordContextLimit = 4
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        #expect(Set(json.keys) == Self.keysOnMain.union(["wordContextLimit"]))
        #expect(json["wordContextLimit"] as? Double == 4)
    }

    @Test func aMissingKeyKeepsTheDefault() throws {
        let read = try JSONDecoder().decode(Classifier.Options.self, from: Data(#"{"threshold": 12}"#.utf8))
        var expected = Classifier.Options()
        expected.threshold = 12
        #expect(read == expected)
    }
}

/// What a recorded selection keeps of the text: its length in the unit the
/// machine counts in.
@Suite struct SelectionMaskTests {
    static func masked(_ text: String) -> String {
        guard case let .selectionRead(_, masked, _) = RecordedEvent(.selectionRead(seq: 1, text: text,
                                                                                    viaAccessibility: false))
        else { return "" }
        return masked
    }

    @Test(arguments: [
        "\u{1F44D}",                          // 👍: one Character, two UTF-16 units
        "e\u{301}",                           // e and a combining acute: one Character, two scalars
        "a\u{1F44D}e\u{301}b",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", // a family: one Character, five scalars
        "\u{1F1F7}\u{1F1FA}",                // a flag: one Character, two scalars
        "при\u{306}вет",                      // Cyrillic with a combining breve
    ])
    func theMaskHasAsManyCharactersAsTheMachineCounts(text: String) {
        let masked = Self.masked(text)
        #expect(masked == String(repeating: "x", count: text.count))
        #expect(masked.count == text.count)
        #expect(masked.unicodeScalars.count == text.count, "only ASCII x")
    }

    @Test func theMaskHasNoTextOfTheSelection() {
        let masked = Self.masked("секрет 👍 e\u{301}")
        #expect(Set(masked) == ["x"])
    }

    /// The length limit of `SelectionConversion` counts `Character`s: a mask
    /// of the same count stays inside it and one over stays out, however many
    /// scalars the characters have.
    @Test func theMaskKeepsTheSideOfTheLengthLimit() {
        let limit = SelectionConversion.maxLength
        for count in [limit, limit + 1] {
            let text = String(repeating: "e\u{301}", count: count)
            #expect(text.unicodeScalars.count == 2 * count)
            #expect(SelectionConversion.isTypable(text) == (count <= limit))
            #expect(SelectionConversion.isTypable(Self.masked(text)) == SelectionConversion.isTypable(text))
        }
    }
}
