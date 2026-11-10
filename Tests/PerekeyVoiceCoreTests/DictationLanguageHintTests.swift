// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyVoiceCore
import Testing

struct DictationLanguageHintTests {
    // MARK: - The decision

    @Test func theAppLanguageThatTheLayoutSharesIsTheHint() {
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: "ru", previous: nil) == "ru")
        #expect(DictationLanguageHint.hint(appLanguage: "en", layoutLanguage: "en", previous: nil) == "en")
    }

    @Test func anUnknownAppLanguageGivesNoHint() {
        #expect(DictationLanguageHint.hint(appLanguage: nil, layoutLanguage: "ru", previous: nil) == nil)
    }

    @Test func anUnknownLayoutLanguageGivesNoHint() {
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: nil, previous: nil) == nil)
    }

    @Test func aLayoutOfAnotherLanguageGivesNoHint() {
        // A Russian app, the English layout selected: the person may well speak English.
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: "en", previous: nil) == nil)
        #expect(DictationLanguageHint.hint(appLanguage: "en", layoutLanguage: "ru", previous: nil) == nil)
    }

    @Test func noInputsGiveNoHint() {
        #expect(DictationLanguageHint.hint(appLanguage: nil, layoutLanguage: nil, previous: nil) == nil)
    }

    @Test func theLastDictationInTheAppAgreeingOrUnknownKeepsTheHint() {
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: "ru", previous: "ru") == "ru")
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: "ru", previous: nil) == "ru")
    }

    @Test func theLastDictationInTheAppInAnotherLanguageTakesTheHintAway() {
        // The person dictates English in a mostly Russian app: a wrong hint is worse than none.
        #expect(DictationLanguageHint.hint(appLanguage: "ru", layoutLanguage: "ru", previous: "en") == nil)
    }

    // MARK: - What the last dictations remember

    @Test func theMemoryKeepsTheLanguageOfEachApp() {
        var memory = LastDictationLanguages()
        #expect(memory.language(app: "com.apple.Notes") == nil)
        memory.record(language: "ru", app: "com.apple.Notes")
        memory.record(language: "en", app: "com.apple.Terminal")
        #expect(memory.language(app: "com.apple.Notes") == "ru")
        #expect(memory.language(app: "com.apple.Terminal") == "en")
        memory.record(language: "en", app: "com.apple.Notes")
        #expect(memory.language(app: "com.apple.Notes") == "en")
    }

    @Test func aDictationOfNoClearLanguageForgetsTheApp() {
        var memory = LastDictationLanguages()
        memory.record(language: "ru", app: "a")
        memory.record(language: nil, app: "a")
        #expect(memory.language(app: "a") == nil)
    }

    @Test func theMemoryStaysSmallAndDropsTheOldest() {
        var memory = LastDictationLanguages(limit: 3)
        for app in ["a", "b", "c", "d"] { memory.record(language: "ru", app: app) }
        #expect(memory.language(app: "a") == nil)
        #expect(["b", "c", "d"].allSatisfy { memory.language(app: $0) == "ru" })
        // A repeated app is the newest again.
        memory.record(language: "ru", app: "b")
        memory.record(language: "ru", app: "e")
        #expect(memory.language(app: "b") == "ru")
        #expect(memory.language(app: "c") == nil)
    }

    // MARK: - The check of a hinted result

    private func audio() -> AudioBuffer16k { AudioBuffer16k([Float](repeating: 0.5, count: 16_000)) }

    @Test func aHintGoesToTheEngine() async throws {
        let engine = FakeEngine(text: "Привет, мир.")
        try await engine.prepare()
        let hint = LanguageHint(language: "ru") { _ in "ru" }
        let outcome = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil, hint: hint)
        #expect(outcome == .text("Привет, мир."))
        #expect(await engine.languages == ["ru"])
    }

    @Test func noHintLeavesTheEngineToFindTheLanguage() async throws {
        let engine = FakeEngine(text: "Привет, мир.")
        try await engine.prepare()
        _ = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil)
        #expect(await engine.languages == [nil])
    }

    @Test func aResultInAnotherLanguageIsRecognizedAgainWithoutTheHint() async throws {
        let engine = FakeEngine(text: "Hello, world.")
        await engine.set(textByLanguage: ["ru": "Хелло, ворлд."])
        try await engine.prepare()
        // The hinted text reads as English, so the hint was wrong.
        let hint = LanguageHint(language: "ru") { _ in "en" }
        let outcome = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil, hint: hint)
        #expect(outcome == .text("Hello, world."))
        #expect(await engine.languages == ["ru", nil])
    }

    @Test func aResultOfNoClearLanguageStays() async throws {
        let engine = FakeEngine(text: "open pull request main")
        try await engine.prepare()
        let hint = LanguageHint(language: "ru") { _ in nil }
        let outcome = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil, hint: hint)
        #expect(outcome == .text("open pull request main"))
        #expect(await engine.languages == ["ru"])
    }

    @Test func theRetryHappensOnlyOnce() async throws {
        let engine = FakeEngine(text: "Hello.")
        try await engine.prepare()
        let hint = LanguageHint(language: "ru") { _ in "en" }
        _ = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil, hint: hint)
        #expect(await engine.languages.count == 2)
    }

    @Test func nothingLeftOfAHintedResultIsNotRetried() async throws {
        let engine = FakeEngine(text: "")
        try await engine.prepare()
        let hint = LanguageHint(language: "ru") { _ in "en" }
        let outcome = try await DictationRecognition.recognize(audio(), engine: engine, detector: nil, hint: hint)
        #expect(outcome == .nothingLeft)
        #expect(await engine.languages == ["ru"])
    }

    @Test func noSpeechNeverReachesTheEngineWithAHint() async throws {
        let engine = FakeEngine(text: "x")
        try await engine.prepare()
        let silence = AudioBuffer16k([Float](repeating: 0, count: 16_000))
        let hint = LanguageHint(language: "ru") { _ in nil }
        let outcome = try await DictationRecognition.recognize(silence, engine: engine, detector: FakeDetector(), hint: hint)
        #expect(outcome == .noSpeech)
        #expect(await engine.languages.isEmpty)
    }
}
