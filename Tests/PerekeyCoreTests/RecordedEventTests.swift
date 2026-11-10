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
        case .voiceHoldLost: "voiceHoldLost"
        case .voiceSession: "voiceSession"
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
            "languageContextChanged", "voiceHoldLost", "voiceSession",
        ]
        // The two cases with their own rules have tests of their own below.
        #expect(sampled == all.subtracting(["selectionRead", "classifierChanged"]))
    }

    @Test(arguments: RecordedEventTests.events.indices)
    func eventSurvivesTheRecording(index: Int) throws {
        let event = Self.events[index]
        let recorded = RecordedEvent(event)
        let read = try Self.roundTrip(recorded)
        #expect(read == recorded)
        let replayed = read.inputEvent(classifier: Self.classifier)
        #expect(Self.name(of: replayed) == Self.name(of: event))
        #expect(RecordedEvent(replayed) == recorded)
    }

    @Test func selectionIsRecordedAsItsLengthOnly() throws {
        let recorded = RecordedEvent(.selectionRead(seq: 4, text: "привет, мир", viaAccessibility: true))
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
        let recorded = RecordedEvent(.classifierChanged(Classifier(model: ModelFixture.model, options: options)))
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
        let recorded = RecordedEvent(.classifierChanged(nil))
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
