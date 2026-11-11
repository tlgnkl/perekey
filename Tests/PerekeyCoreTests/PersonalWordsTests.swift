// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

/// The personal lexicon in the classifier: a word the user keeps typing reads
/// as a known form (docs/classifier.md, «Личный словарь»). «Дашка» is no word
/// of the fixture model: alone, "lfirf" stays.
@Suite struct PersonalClassifierTests {
    let classifier = Desk.classifier
    let dashka = personalLexicon([("дашка", "ru")])

    func decide(_ text: String, typed: LayoutMap, other: LayoutMap, personal: PersonalLexicon,
                explaining: Bool = false) -> Classifier.Decision
    {
        classifier.classify(typed.strokes(text), typed: typed, other: other,
                            context: Classifier.Context(recent: RecentLanguages(), personal: personal),
                            explaining: explaining)
    }

    @Test func aPersonalWordInTheWrongLayoutSwitches() {
        #expect(decide("lfirf", typed: Fixture.abc, other: Fixture.russian, personal: .off).verdict == .keep)
        #expect(decide("lfirf", typed: Fixture.abc, other: Fixture.russian, personal: dashka).verdict
            == .switch(to: ru))
        // Typed right, it stays, with more to spare than without the lexicon.
        let alone = decide("дашка", typed: Fixture.russian, other: Fixture.abc, personal: .off)
        let known = decide("дашка", typed: Fixture.russian, other: Fixture.abc, personal: dashka)
        #expect(known.verdict == .keep && known.score < alone.score)
    }

    @Test func theRankIsAnOption() {
        var options = Desk.classifier.options
        #expect(options.personalRank == 128)
        options.personalRank = 0
        let classifier = Classifier(model: ModelFixture.model, options: options)
        let higher = Desk.classifier
        let context = Classifier.Context(recent: RecentLanguages(), personal: dashka)
        let strokes = Fixture.abc.strokes("lfirf")
        let low = classifier.classify(strokes, typed: Fixture.abc, other: Fixture.russian, context: context,
                                      explaining: true)
        let high = higher.classify(strokes, typed: Fixture.abc, other: Fixture.russian, context: context,
                                   explaining: true)
        #expect(low.otherRank == 0 && high.otherRank == 128)
        #expect(high.score > low.score)
    }

    @Test func theDecisionSaysWhichReadingIsPersonal() {
        let decision = decide("lfirf", typed: Fixture.abc, other: Fixture.russian, personal: dashka, explaining: true)
        #expect(decision.otherPersonal && !decision.typedPersonal)
        #expect(decision.otherForm == .known)
        let explanation = Explanation(decision: decision, typed: "lfirf", other: "дашка")
        #expect(explanation.statements.contains(.personal(text: "дашка")))
        #expect(!explanation.statements.contains { if case .reading(text: "дашка", _, _) = $0 { true } else { false } })
        let plain = decide("lfirf", typed: Fixture.abc, other: Fixture.russian, personal: .off, explaining: true)
        #expect(!plain.otherPersonal && !plain.typedPersonal)
    }

    @Test func theDecisionSaysWhatTheModelKnowsWithoutTheLexicon() {
        // What the word judge skips the observation by.
        let known = decide("привет", typed: Fixture.russian, other: Fixture.abc, personal: dashka)
        #expect(known.typedKnown && !known.otherKnown)
        let personal = decide("lfirf", typed: Fixture.abc, other: Fixture.russian, personal: dashka)
        #expect(!personal.typedKnown && !personal.otherKnown && personal.otherPersonal)
        #expect(classifier.isPlainlyKnown(Fixture.russian.strokes("Привет "), in: Fixture.russian))
        #expect(!classifier.isPlainlyKnown(Fixture.russian.strokes("дашка"), in: Fixture.russian))
        // Marks around the word: no plain answer, the reading decides.
        #expect(!classifier.isPlainlyKnown(Fixture.russian.strokes("привет!"), in: Fixture.russian))
    }

    @Test func aKnownWordIsNotLookedUp() {
        // «привет» is in the model: its rank stays the model's.
        let lexicon = personalLexicon([("привет", "ru")])
        let decision = decide("ghbdtn", typed: Fixture.abc, other: Fixture.russian, personal: lexicon, explaining: true)
        #expect(!decision.otherPersonal && decision.otherRank == 200)
    }

    @Test func aMarkOnALetterKeyStaysAMark() {
        // "," on ABC is "б" in Russian: "Дашка," and not "Дашкаб".
        let strokes = Fixture.abc.strokes("Lfirf,")
        let decision = classifier.classify(strokes, typed: Fixture.abc, other: Fixture.russian,
                                           context: Classifier.Context(recent: RecentLanguages(), personal: dashka))
        #expect(decision.verdict == .switch(to: ru))
        #expect(decision.punctuationKeys == 1)
        // The same rule after a switch inside the word.
        #expect(classifier.marksAfterSwitch(strokes, in: Fixture.russian, from: Fixture.abc, personal: dashka) == 1)
        #expect(classifier.marksAfterSwitch(strokes, in: Fixture.russian, from: Fixture.abc) == 0)

        var desk = Desk()
        desk.send(.personalLexiconChanged(dashka))
        desk.type("Lfirf, ")
        #expect(desk.text == "Дашка, ")
    }

    @Test func theGuardsStayStronger() {
        // Digits: never switched.
        let digits = personalLexicon([("дашка1", "ru")])
        #expect(decide("lfirf1", typed: Fixture.abc, other: Fixture.russian, personal: digits).reason == .digits)
        // A capital inside: «ДашКа» is no frequent word.
        let mixed = decide("LfirF", typed: Fixture.abc, other: Fixture.russian, personal: dashka)
        #expect(mixed.verdict == .keep && mixed.reason == .mixedCase)
    }

    @Test func theNeverSwitchListStaysStronger() throws {
        // A word of the model's never-switch list is kept whatever the lexicon says.
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        builder.addForm("привет", language: "ru", rank: 200, weight: 200)
        builder.addForm("hello", language: "en", rank: 200, weight: 200)
        builder.addKeep("lfirf")
        let model = try LanguageModel(bytes: builder.build())
        let decision = Classifier(model: model).classify(
            Fixture.abc.strokes("lfirf"), typed: Fixture.abc, other: Fixture.russian,
            context: Classifier.Context(recent: RecentLanguages(), personal: dashka)
        )
        #expect(decision.verdict == .keep && decision.reason == .kept)
    }
}

/// The user's lists stay stronger than the lexicon in the word judge.
@Suite struct PersonalListsTests {
    let dashka = personalLexicon([("дашка", "ru")])

    @Test func anExceptionKeepsThePersonalWord() {
        var desk = Desk(Settings(exceptions: ["lfirf"]))
        desk.send(.personalLexiconChanged(dashka))
        desk.type("lfirf ")
        #expect(desk.text == "lfirf ")

        var other = Desk(Settings(exceptions: ["дашка"]))
        other.send(.personalLexiconChanged(dashka))
        other.type("lfirf ")
        #expect(other.text == "lfirf ")
    }

    @Test func alwaysFixWinsOverThePersonalWord() {
        // The list says "lfirf" typed in Russian is meant as "lfirf" in English.
        var desk = Desk(Settings(alwaysFix: WordRules(always: ["lfirf"]).alwaysFixTable), current: ru)
        desk.send(.personalLexiconChanged(dashka))
        desk.type("дашка ", on: Fixture.russian)
        #expect(desk.text == "lfirf ")
    }

    @Test func thePersonalWordIsNoTypo() {
        // «прмвет» is one key off «привет»: the corrector fixes it, unless the
        // user keeps typing it.
        var plain = Desk(Settings(typoCorrection: true), current: ru)
        plain.type("прмвет ", on: Fixture.russian)
        #expect(plain.text == "привет ")

        var desk = Desk(Settings(typoCorrection: true), current: ru)
        desk.send(.personalLexiconChanged(personalLexicon([("прмвет", "ru")])))
        desk.type("прмвет ", on: Fixture.russian)
        #expect(desk.text == "прмвет ")
    }

    @Test func aPersonalStartHoldsTheSwitchInsideTheWord() {
        // "ghb" starts no English word and is "при" in Russian: it switches at
        // the third key. A nickname that starts so waits for its end.
        var plain = Desk()
        plain.type("ghbnz ")
        #expect(plain.text != "ghbnz ")

        var desk = Desk()
        desk.send(.personalLexiconChanged(personalLexicon([("ghbnz", "en")])))
        desk.type("ghbnz ")
        #expect(desk.text == "ghbnz ")
        #expect(desk.corrections.isEmpty)
    }
}

/// When a word may teach the lexicon, and what drops it (plan 7.2, items 5–6).
@Suite struct PersonalObservationTests {
    static let textEdit = LanguageContext(app: "com.apple.TextEdit")
    static let classifier = Desk.classifier
    let classifier = PersonalObservationTests.classifier
    let corrector = TypoCorrector(model: ModelFixture.model)
    let on = personalLexicon([])

    /// A desk in TextEdit, whose words count, with the lexicon on.
    func desk(_ settings: Settings = Settings(), current: LayoutID = ru, personal: PersonalLexicon? = nil,
              counted: Bool = true, focus: Focus? = Desk.textEdit) -> Desk
    {
        var desk = Desk(settings, current: current, classifier: classifier, focus: focus)
        if counted { desk.send(.languageContextChanged(Self.textEdit)) }
        desk.send(.personalLexiconChanged(personal ?? on))
        return desk
    }

    func kept(_ desk: Desk) -> [PersonalObservation] {
        desk.machine.snapshot.personalKept ?? []
    }

    func observe(_ text: String, in layout: LayoutMap, rivals: [LayoutMap],
                 personal: PersonalLexicon? = nil) -> PersonalObservation?
    {
        classifier.personalObservation(layout.strokes(text), in: layout, rivals: rivals, personal: personal ?? on,
                                       typo: TypoCheck(corrector: corrector, sentenceStart: false))
    }

    // MARK: Conditions 3–6, in the classifier

    @Test func anUnknownWordWithoutARivalIsObserved() {
        #expect(observe("дашка", in: Fixture.russian, rivals: [Fixture.abc]) == personalObservation("дашка", "ru"))
        #expect(observe("Дашка", in: Fixture.russian, rivals: [Fixture.abc]) == personalObservation("дашка", "ru"))
        // Marks around the word are no part of it.
        #expect(observe("(дашка),", in: Fixture.russian, rivals: [Fixture.abc]) == personalObservation("дашка", "ru"))
        // Three letters is the least.
        #expect(observe("дшк", in: Fixture.russian, rivals: [Fixture.abc])?.start4 == nil)
        #expect(observe("дшк", in: Fixture.russian, rivals: [Fixture.abc]) != nil)
    }

    @Test func offObservesNothing() {
        #expect(observe("дашка", in: Fixture.russian, rivals: [Fixture.abc], personal: .off) == nil)
    }

    @Test(arguments: ["дашка1", "дш", String(repeating: "дашка", count: 5), "даШка", "даш!ка"])
    func onlyAPlainWordOfLetters(text: String) {
        #expect(observe(text, in: Fixture.russian, rivals: [Fixture.abc]) == nil)
    }

    @Test func aPasswordIsNoWord() {
        #expect(observe("Lfirf!q", in: Fixture.abc, rivals: [Fixture.russian]) == nil)
    }

    @Test func aWordOfTheNeverSwitchListIsNoCandidate() throws {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        builder.addForm("hello", language: "en", rank: 200, weight: 200)
        builder.addKeep("zork")
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        let classifier = Classifier(model: try LanguageModel(bytes: builder.build()), options: options)
        let strokes = Fixture.abc.strokes("zork")
        #expect(classifier.personalObservation(strokes, in: Fixture.abc, rivals: [Fixture.russian], personal: on,
                                               typo: nil) == nil)
        #expect(classifier.personalObservation(Fixture.abc.strokes("zorg"), in: Fixture.abc, rivals: [Fixture.russian],
                                               personal: on, typo: nil) != nil)
    }

    @Test func aKnownWordIsNoCandidate() {
        #expect(observe("привет", in: Fixture.russian, rivals: [Fixture.abc]) == nil)
    }

    @Test func aWordWithAKnownRivalIsNoCandidate() {
        // "ghbdtn" left by oversight: its rival is «привет».
        #expect(observe("ghbdtn", in: Fixture.abc, rivals: [Fixture.russian]) == nil)
        #expect(observe("ghbdtn", in: Fixture.abc, rivals: []) != nil)
    }

    @Test func aTypoTheCorrectorFixesIsNoCandidate() {
        #expect(observe("прмвет", in: Fixture.russian, rivals: [Fixture.abc]) == nil)
        #expect(classifier.personalObservation(Fixture.russian.strokes("прмвет"), in: Fixture.russian,
                                               rivals: [Fixture.abc], personal: on,
                                               typo: nil) != nil)
    }

    // MARK: Conditions 1, 2, 5, 7, 8 and the confirmation, in the machine

    @Test func aKeptWordIsTakenWhenTheNextWordStarts() {
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        #expect(desk.machine.judge.pendingObservation == personalObservation("дашка", "ru"))
        #expect(!desk.machine.isQuiet)
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func aLineEndTakesItAtOnce() {
        var desk = desk()
        desk.type("дашка", on: Fixture.russian)
        desk.press(KeyCode.return)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func notWhereAutomaticSwitchingCannotAct() {
        var off = desk(Settings(autoswitch: false))
        off.type("дашка и", on: Fixture.russian)
        #expect(kept(off).isEmpty)

        var manual = desk()
        manual.send(.appModeChanged(.manualOnly))
        manual.type("дашка и", on: Fixture.russian)
        #expect(kept(manual).isEmpty)

        var unknown = desk(focus: .unknown(bundleID: Desk.textEdit.bundleID))
        unknown.type("дашка и", on: Fixture.russian)
        #expect(kept(unknown).isEmpty)

        var secure = desk(focus: Focus(bundleID: Desk.textEdit.bundleID, isSecureField: true))
        secure.type("дашка и", on: Fixture.russian)
        #expect(kept(secure).isEmpty)

        var secureInput = desk()
        secureInput.send(.secureInputChanged(true))
        secureInput.type("дашка и", on: Fixture.russian)
        #expect(kept(secureInput).isEmpty)
    }

    @Test func notWhereWordsDoNotCount() {
        // No language context for the focus: Perekey's own windows, or the
        // moment the focus moved and the context did not yet.
        var desk = desk(counted: false)
        desk.type("дашка и", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
    }

    @Test func notWithTheLexiconOff() {
        var desk = desk(personal: .off)
        desk.type("дашка и", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        #expect(desk.machine.judge.pendingObservation == nil)
    }

    @Test func notAWordTypedWithOption() {
        var desk = desk()
        desk.type("дашк", on: Fixture.russian)
        desk.press(Fixture.russian.strokes("а")[0].keyCode, flags: Keyboard.leftOption)
        desk.type(" и", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
    }

    @Test func notAWordTheClassifierIsUnsureAbout() {
        // «лиза» in the lexicon makes "kbpf" a near switch: unsure, so the
        // typed reading teaches nothing. Without it "kbpf" is kept outright.
        var unsure = desk(current: en, personal: personalLexicon([("лиза", "ru")]))
        unsure.type("kbpf v")
        #expect(unsure.text == "kbpf v")
        #expect(kept(unsure).isEmpty)

        var plain = desk(current: en)
        plain.type("kbpf v")
        #expect(kept(plain) == [personalObservation("kbpf", "en")])
    }

    @Test func notAWordACorrectionChanged() {
        // The typo step fixes it: nothing to learn, whether or not the word is a candidate.
        var typo = desk(Settings(typoCorrection: true))
        typo.type("прмвет и", on: Fixture.russian)
        #expect(typo.text == "привет и")
        #expect(kept(typo).isEmpty)

        // A switch the always-fix list forced.
        var listed = desk(Settings(alwaysFix: WordRules(always: ["аня"]).alwaysFixTable), current: en)
        listed.type("Fyz d")
        #expect(listed.text.hasPrefix("Аня "))
        #expect(kept(listed).isEmpty)
    }

    @Test func aSwitchThatStoodTeachesItsResult() {
        // "lfirf" goes to «Дашка» thanks to the lexicon; the result is seen again,
        // by its fingerprint alone: the lexicon has its starts.
        var desk = desk(current: en, personal: personalLexicon([("дашка", "ru")]))
        desk.type("lfirf ")
        #expect(desk.text == "дашка ")
        #expect(kept(desk).isEmpty)
        desk.type("b")
        let fingerprint = personalKey.fingerprint(ofWord: "дашка", language: "ru")
        #expect(kept(desk) == [PersonalObservation(word: fingerprint, start3: nil, start4: nil, language: "ru")])
    }

    @Test func aSwitchInsideTheWordThatStoodTeachesItsResult() {
        // "ghb" switches at once; «приветик» is no word of the model.
        var desk = desk(current: en)
        desk.type("ghbdtnbr ")
        #expect(desk.text == "приветик ")
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("приветик", "ru")])
    }

    // MARK: What drops the observation

    @Test func backspaceDropsIt() {
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        desk.press(KeyCode.delete)
        #expect(desk.machine.judge.pendingObservation == nil)
        // The word typed on is another one, and it is what counts.
        desk.type("у и", on: Fixture.russian)
        #expect(!kept(desk).contains(personalObservation("дашка", "ru")))
    }

    @Test func theWordGoingOnDropsIt() {
        // Ended by "!", then more letters: "дашка!x" is no word.
        var desk = desk()
        desk.type("дашка!", on: Fixture.russian)
        desk.type("ъ", on: Fixture.russian)
        #expect(desk.machine.judge.pendingObservation == nil)
    }

    @Test func anUndoDropsIt() {
        var desk = desk(current: en, personal: personalLexicon([("дашка", "ru")]))
        desk.type("lfirf ")
        #expect(desk.text == "дашка ")
        desk.send(.undoLastCorrection(seq: desk.corrections[0].seq, time: desk.time))
        desk.settle()
        #expect(desk.text == "lfirf ")
        desk.type("b")
        #expect(kept(desk).isEmpty)
    }

    @Test func aRetypeByHandDropsIt() {
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        #expect(desk.machine.judge.pendingObservation != nil)
        // ⌥ alone: the default shortcut retypes the last word into the other layout.
        desk.tapOption()
        #expect(desk.text == "lfirf ")
        #expect(desk.machine.judge.pendingObservation == nil)
        desk.type("b")
        #expect(kept(desk).isEmpty)
    }

    @Test(arguments: [0, 1, 2])
    func whateverForgetsTheTextDropsIt(kind: Int) {
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        switch kind {
        case 0: desk.send(.click(time: desk.time + 1))
        case 1: desk.send(.focusChanged(Focus(bundleID: "com.apple.Notes")))
        default: desk.send(.inputLost)
        }
        #expect(desk.machine.judge.pendingObservation == nil)
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
    }

    // MARK: The batch

    @Test func theBatchGoesWithTheContextChange() {
        var desk = desk()
        desk.type("дашка и", on: Fixture.russian)
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Notes")))
        let batches = desk.log.compactMap { if case let .wordsKept(tally) = $0 { tally } else { nil } }
        #expect(batches == [PersonalTally(observations: [personalObservation("дашка", "ru")], generation: 0)])
        #expect(kept(desk).isEmpty)
    }

    @Test func theBatchGoesWhenFull() {
        var desk = desk()
        for _ in 0..<WordJudge.tallySize { desk.type("дашка ", on: Fixture.russian) }
        desk.type("и ", on: Fixture.russian)
        let batches = desk.log.compactMap { if case let .wordsKept(tally) = $0 { tally } else { nil } }
        #expect(batches.count == 1)
        #expect(batches.first?.observations.count == WordJudge.tallySize)
    }

    @Test func aNewGenerationDropsTheOldBatch() {
        var desk = desk()
        desk.type("дашка и", on: Fixture.russian)
        #expect(kept(desk).count == 1)
        desk.send(.personalLexiconChanged(personalLexicon([], generation: 1)))
        #expect(kept(desk).isEmpty)
        desk.type(" колян и", on: Fixture.russian)
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Notes")))
        let batches = desk.log.compactMap { if case let .wordsKept(tally) = $0 { tally } else { nil } }
        #expect(batches.map(\.generation) == [1])
        // The store drops a batch of an older generation (`PersonalLexiconModel.record`).
    }

    @Test func turningItOffDropsEverything() {
        var desk = desk()
        desk.type("дашка и", on: Fixture.russian)
        desk.send(.personalLexiconChanged(.off))
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Notes")))
        #expect(!desk.log.contains { if case .wordsKept = $0 { true } else { false } })
    }

    @Test func theSnapshotCarriesTheLexiconAndTheBatch() throws {
        var desk = desk(personal: personalLexicon([("колян", "ru")], generation: 2))
        desk.type("дашка и", on: Fixture.russian)
        let snapshot = desk.machine.snapshot
        let read = try JSONDecoder().decode(MachineSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(read == snapshot)
        #expect(read.personalLexicon == personalLexicon([("колян", "ru")], generation: 2))
        #expect(read.personalKept == [personalObservation("дашка", "ru")])
        let machine = InputMachine(snapshot: read, classifier: Desk.classifier)
        #expect(machine.snapshot == snapshot)
        // Off leaves both out: a file from before the lexicon reads the same.
        var plain = Desk()
        plain.type("дашка и", on: Fixture.russian)
        let json = try #require(String(data: JSONEncoder().encode(plain.machine.snapshot), encoding: .utf8))
        #expect(!json.contains("personal"))
    }

    @Test func noTextInTheEffectOrTheSnapshot() throws {
        var desk = desk()
        desk.type("дашка и", on: Fixture.russian)
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Notes")))
        let batches = desk.log.compactMap { if case let .wordsKept(tally) = $0 { tally } else { nil } }
        let json = try #require(String(data: JSONEncoder().encode(batches), encoding: .utf8))
        #expect(!json.contains("дашка") && !json.contains("даш") && !json.contains("lfirf"))
        let unkeyed = String(ModelFormat.Fingerprint.of("дашка".unicodeScalars, folded: true), radix: 16)
        #expect(!json.contains(unkeyed))
    }
}

// MARK: - The review of the core: the tap's work, the privacy, the order of the checks

extension PersonalObservationTests {
    // MARK: The batch buffers (plan 2.2: nothing allocates per word)

    @Test func theBuffersKeepTheirRoomThroughABatch() {
        var desk = desk()
        let room = WordJudge.keptCapacity
        #expect(room == WordJudge.tallySize + 1)
        #expect(desk.machine.judge.keptCapacity >= room)
        #expect(desk.machine.judge.spareCapacity >= room)
        // A batch leaves with its buffer; the spare takes its place at once.
        for _ in 0..<WordJudge.tallySize { desk.type("дашка ", on: Fixture.russian) }
        desk.type("и ", on: Fixture.russian)
        #expect(desk.log.contains { if case .wordsKept = $0 { true } else { false } })
        let after = desk.machine.judge.keptCapacity
        #expect(after >= room && desk.machine.judge.spareCapacity >= room)
        // The words of the next batch grow nothing.
        for _ in 0..<(WordJudge.tallySize / 2) { desk.type("колян ", on: Fixture.russian) }
        #expect(desk.machine.judge.keptCapacity == after)
    }

    @Test func offKeepsNoRoom() {
        var desk = desk()
        desk.send(.personalLexiconChanged(.off))
        #expect(desk.machine.judge.keptCapacity == 0 && desk.machine.judge.spareCapacity == 0)
    }

    // MARK: A word the lexicon has is counted by the fingerprint the classifier found

    @Test func aWordOfTheLexiconIsCountedWithoutStarts() {
        var desk = desk(personal: personalLexicon([("дашка", "ru")]))
        desk.type("дашка и", on: Fixture.russian)
        let fingerprint = personalKey.fingerprint(ofWord: "дашка", language: "ru")
        #expect(kept(desk) == [PersonalObservation(word: fingerprint, start3: nil, start4: nil, language: "ru")])
    }

    @Test func aKnownFingerprintSkipsTheRivalTheTypoAndTheHash() {
        // "прмвет" is a typo the corrector fixes, and «привет» is its rival in
        // English layout: an unknown word is no candidate...
        let strokes = Fixture.russian.strokes("прмвет")
        #expect(classifier.personalObservation(strokes, in: Fixture.russian, rivals: [Fixture.abc], personal: on,
                                               typo: TypoCheck(corrector: corrector, sentenceStart: false)) == nil)
        // ...and a word the lexicon already has is counted whatever they say.
        let counted = classifier.personalObservation(strokes, in: Fixture.russian, rivals: [Fixture.abc], personal: on,
                                                     typo: TypoCheck(corrector: corrector, sentenceStart: false),
                                                     known: 42)
        #expect(counted == PersonalObservation(word: 42, start3: nil, start4: nil, language: "ru"))
    }

    @Test func aKnownFingerprintStillNeedsAWordOfLetters() {
        for text in ["дашка1", "дш", "даШка"] {
            let strokes = Fixture.russian.strokes(text)
            #expect(classifier.personalObservation(strokes, in: Fixture.russian, rivals: [Fixture.abc], personal: on,
                                                   typo: nil, known: 42) == nil, "\(text)")
        }
    }

    @Test func theDecisionKnowsNothingAboutTheModelWhileTheLexiconIsOff() {
        let classifier = Classifier(model: ModelFixture.model)
        func decide(_ personal: PersonalLexicon) -> Classifier.Decision {
            classifier.classify(Fixture.abc.strokes("ghbdtn"), typed: Fixture.abc, other: Fixture.russian,
                                context: Classifier.Context(recent: RecentLanguages(), personal: personal))
        }
        let off = decide(.off)
        #expect(!off.typedKnown && !off.otherKnown && off.typedPersonalWord == 0)
        let on = decide(personalLexicon([]))
        #expect(on.otherKnown && !on.typedKnown)
    }

    // MARK: Condition 6 as the corrector is asked

    @Test func theCorrectorIsAskedWithTheWordBefore() {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        var classifier = Classifier(model: TypoContextCorrectorTests.model, options: options)
        classifier.typoContextWeight = 1
        func pending(_ text: String) -> PersonalObservation? {
            // The typo step is off: it would fix "of thenm" itself. The
            // observation asks the corrector all the same, with the word before.
            var desk = Desk(Settings(typoCorrection: false), classifier: classifier)
            desk.send(.languageContextChanged(Self.textEdit))
            desk.send(.personalLexiconChanged(on))
            desk.type(text)
            #expect(desk.text == text)
            return desk.machine.judge.pendingObservation
        }
        // "of thenm" is "of them" for the corrector; after "said" it is no typo it would fix.
        #expect(pending("of thenm ") == nil)
        #expect(pending("said thenm ") != nil)
    }

    // MARK: The confirmation is the first letter of the next word

    @Test func aDigitDoesNotTakeIt() {
        var desk = desk()
        desk.type("дашка 5", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        #expect(desk.machine.judge.pendingObservation == personalObservation("дашка", "ru"))
        desk.type(" и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func aMarkDoesNotTakeItAndTheLetterAfterItDoes() {
        var desk = desk()
        desk.type("дашка (", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        #expect(desk.machine.judge.pendingObservation != nil)
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func marksAndDigitsInARowKeepItWaiting() {
        var desk = desk()
        desk.type("дашка ((5", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        #expect(desk.machine.judge.pendingObservation != nil)
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func aLineEndAfterDigitsTakesIt() {
        var desk = desk()
        desk.type("дашка 5", on: Fixture.russian)
        #expect(kept(desk).isEmpty)
        desk.press(KeyCode.return)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func aLineEndAfterTheSpaceCountsTheWordOnce() {
        // The space judged the word, Return does not judge it again: it takes the
        // observation, and the next line's first letter finds nothing to take twice.
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        desk.press(KeyCode.return)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
        desk.type("и", on: Fixture.russian)
        #expect(kept(desk) == [personalObservation("дашка", "ru")])
    }

    @Test func aReturnWithACommandKeyIsNoLineEnd() {
        var desk = desk()
        desk.type("дашка ", on: Fixture.russian)
        desk.press(KeyCode.return, flags: Keyboard.leftCommand)
        #expect(kept(desk).isEmpty && desk.machine.judge.pendingObservation == nil)
    }

    @Test func aLetterTakesItOnlyOnce() {
        var desk = desk()
        desk.type("дашка и", on: Fixture.russian)
        desk.type("ну", on: Fixture.russian)
        #expect(kept(desk).count == 1)
    }

    // MARK: A switch inside the word follows the always-fix list too

    @Test func aSwitchInsideTheWordOfTheAlwaysFixListTeachesNothing() {
        var listed = desk(Settings(alwaysFix: WordRules(always: ["приветик"]).alwaysFixTable), current: en)
        listed.type("ghbdtnbr ")
        listed.type("и", on: Fixture.russian)
        #expect(kept(listed).isEmpty)
    }

    // MARK: Condition 3: not a random string

    @Test func theNoiseLimitIsAnOption() {
        func observed(_ limit: Double) -> PersonalObservation? {
            var options = Classifier.Options()
            options.personalNoiseCost = limit
            return Classifier(model: ModelFixture.model, options: options)
                .personalObservation(Fixture.russian.strokes("дашка"), in: Fixture.russian, rivals: [Fixture.abc],
                                     personal: on, typo: nil)
        }
        #expect(observed(.infinity) == personalObservation("дашка", "ru"))
        #expect(observed(0) == nil)
        #expect(Classifier.Options().personalNoiseCost == 11)
    }

    // MARK: No typed word on disk or in a log (plan 2.1, items 1–2)

    @Test func noTypedWordInAnyEncodedForm() throws {
        var desk = desk(personal: personalLexicon([("колян", "ru")], generation: 2))
        let typed = ["дашка", "dashka", "лиза", "zorg", "колян"]
        for word in typed {
            let cyrillic = word.unicodeScalars.first!.value > 0x400
            desk.type("\(word) \(cyrillic ? "и" : "a") ", on: cyrillic ? Fixture.russian : Fixture.abc)
        }
        desk.send(.languageContextChanged(LanguageContext(app: "com.apple.Notes")))
        let effects = desk.log.filter { if case .wordsKept = $0 { true } else { false } }
        #expect(!effects.isEmpty)
        let tallies = effects.compactMap { if case let .wordsKept(tally) = $0 { tally } else { nil } }
        var encoded: [Data] = []
        encoded.append(try JSONEncoder().encode(effects.map(EffectDigest.init)))
        encoded.append(try JSONEncoder().encode(tallies))
        encoded.append(try JSONEncoder().encode(desk.machine.snapshot.personalLexicon))
        encoded.append(try JSONEncoder().encode(desk.machine.snapshot.personalKept ?? []))
        encoded.append(try JSONEncoder().encode(desk.machine.snapshot))
        let words = typed + ["дашк", "даш", "dash", "lfirf", "kbpf", "ккуяу"]
        for data in encoded {
            let text = String(decoding: data, as: UTF8.self)
            for word in words { #expect(!text.contains(word), "\(word) in \(text.prefix(80))") }
        }
    }
}

@Suite struct LetterTests {
    @Test func theRangesAgreeWithUnicode() {
        // Every scalar of the ranges the fast path answers for, against the property.
        for value in UInt32(0)...0x52F {
            guard let scalar = Unicode.Scalar(value) else { continue }
            #expect(WordJudge.isLetter(scalar) == scalar.properties.isAlphabetic, "U+\(String(value, radix: 16))")
        }
        for scalar in ["中", "é", "ß", "ё", "5", "-", " "].compactMap(\.unicodeScalars.first) {
            #expect(WordJudge.isLetter(scalar) == scalar.properties.isAlphabetic)
        }
    }
}

/// A reading costlier than a candidate may be is not looked up (the wrong
/// layout's gibberish is the common case on every word).
@Suite struct PersonalCostPruneTests {
    @Test func aReadingAboveTheLimitIsNotLookedUp() {
        let lexicon = personalLexicon([("дашка", "ru")])
        let context = Classifier.Context(recent: RecentLanguages(), personal: lexicon)
        func personal(_ limit: Double) -> Bool {
            var options = Classifier.Options()
            options.personalNoiseCost = limit
            return Classifier(model: ModelFixture.model, options: options)
                .classify(Fixture.abc.strokes("lfirf"), typed: Fixture.abc, other: Fixture.russian, context: context)
                .otherPersonal
        }
        #expect(personal(.infinity))
        #expect(!personal(0))
    }
}
