// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyVoiceCore
import Testing

struct TextRulesTests {
    private let dictionary = [
        DictionaryEntry(from: "перекей", to: "Perekey"),
        DictionaryEntry(from: "эн-эй-эс-эй", to: "NASA"),
        DictionaryEntry(from: "ай фон", to: "iPhone"),
        DictionaryEntry(from: "парракит", to: "Parakeet"),
        DictionaryEntry(from: "open ai", to: "OpenAI"),
    ]

    private func rules(_ text: String, _ before: String? = nil, fillers: Bool = true) -> String {
        TextRules.apply(text, before: before, dictionary: dictionary, removesFillers: fillers)
    }

    // MARK: Dictionary

    @Test func dictionaryReplacesWholeWordsWhateverTheCase() {
        #expect(rules("Перекей работает") == "Perekey работает")
        #expect(rules("включи ПЕРЕКЕЙ сейчас") == "включи Perekey сейчас")
        #expect(rules("open ai и Open AI") == "OpenAI и OpenAI")
    }

    @Test func dictionaryLeavesTheInsideOfWordsAlone() {
        #expect(rules("перекеи и перекейный") == "перекеи и перекейный")
        #expect(rules("суперперекей") == "суперперекей")
    }

    @Test func dictionaryHandlesPunctuationAndPhrases() {
        #expect(rules("Это перекей, да.") == "Это Perekey, да.")
        #expect(rules("купил ай   фон вчера") == "купил iPhone вчера")
        #expect(rules("Спросил (перекей)?") == "Спросил (Perekey)?")
    }

    @Test func dictionaryReplacementsAreNotChained() {
        let loop = [DictionaryEntry(from: "a", to: "b"), DictionaryEntry(from: "b", to: "c")]
        #expect(TextRules.apply("a b", before: nil, dictionary: loop) == "b c")
    }

    @Test func mixedLanguagePhraseKeepsBothParts() {
        #expect(rules("Открой перекей и покажи settings") == "Открой Perekey и покажи settings")
    }

    // MARK: Fillers

    @Test func hardFillersGo() {
        #expect(rules("Э-э, привет") == "Привет")
        #expect(rules("Я, э-э, думаю") == "Я, думаю")
        #expect(rules("Я э-э-э думаю") == "Я думаю")
        #expect(rules("Ну м-м хорошо") == "Ну хорошо")
        #expect(rules("Это эм странно") == "Это странно")
        #expect(rules("Well, um, yes") == "Well, yes")
        #expect(rules("I uh think so") == "I think so")
        #expect(rules("It is, erm, fine") == "It is, fine")
        #expect(rules("Hello. Um, world") == "Hello. World")
    }

    @Test func fillerAtTheEndKeepsTheSentenceEnd() {
        #expect(rules("Я думаю, um.") == "Я думаю.")
        #expect(rules("Done, uh") == "Done")
    }

    @Test func onlyFillersLeaveNothing() {
        #expect(rules("Э-э...") == "")
        #expect(rules("Um, uh") == "")
        #expect(rules("   ") == "")
    }

    @Test func softFillersGoOnlyAsAsides() {
        #expect(rules("Я, как бы, думаю") == "Я, думаю")
        #expect(rules("Это, типа, круто") == "Это, круто")
        #expect(rules("It was, like, huge") == "It was, huge")
        #expect(rules("Ну, давай") == "Давай")
        #expect(rules("Хорошо. Ну, пойдём") == "Хорошо. Пойдём")
    }

    @Test func softFillersStayWhenTheyMeanSomething() {
        #expect(rules("Ну давай") == "Ну давай")
        #expect(rules("Он сделал как бы случайно") == "Он сделал как бы случайно")
        #expect(rules("Это типа нашего") == "Это типа нашего")
        #expect(rules("I like apples") == "I like apples")
        #expect(rules("Ну и ну") == "Ну и ну")
    }

    @Test func fillersCanBeKept() {
        #expect(rules("Э-э, привет", fillers: false) == "Э-э, привет")
        #expect(rules("Я, как бы, думаю", fillers: false) == "Я, как бы, думаю")
    }

    @Test func fillerLookalikesStay() {
        #expect(rules("Эмоции и umbrella") == "Эмоции и umbrella")
        #expect(rules("кто-то эмм") == "кто-то")
    }

    // MARK: Case

    @Test func capitalAtTheStartOfASentence() {
        #expect(rules("привет", "") == "Привет")
        #expect(rules("Привет", "Раньше. ") == "Привет")
        #expect(rules("привет", "Раньше.") == " Привет")
        #expect(rules("привет", "Что? ") == "Привет")
        #expect(rules("привет", "Да!\n") == "Привет")
        #expect(rules("hello", "Done… ") == "Hello")
        #expect(rules("hello", "He said \"stop.\" ") == "Hello")
        #expect(rules("hello", "   ") == "Hello")
    }

    @Test func lowercaseInTheMiddleOfASentence() {
        #expect(rules("Привет", "Я хочу сказать ") == "привет")
        #expect(rules("Привет мир", "а потом, ") == "привет мир")
        #expect(rules("Hello there", "and then ") == "hello there")
        #expect(rules("Это работает", "Список:") == " это работает")
    }

    @Test func namesAndAbbreviationsKeepTheirCapital() {
        #expect(rules("NASA запустила", "Вчера ") == "NASA запустила")
        #expect(rules("Perekey работает", "Говорят, ") == "Perekey работает")
        #expect(rules("перекей работает", "Говорят, ") == "Perekey работает")
        #expect(rules("iPhone вышел", "Новый ") == "iPhone вышел")
        #expect(rules("I think so", "Well, ") == "I think so")
        #expect(rules("I'm sure", "Well, ") == "I'm sure")
        #expect(rules("OpenAI wrote", "said ") == "OpenAI wrote")
    }

    @Test func caseStaysWithoutContext() {
        #expect(rules("Привет мир", nil) == "Привет мир")
        #expect(rules("привет мир", nil) == "привет мир")
    }

    // MARK: Space

    @Test func spaceAfterLettersDigitsAndClosers() {
        #expect(rules("мир", "привет") == " мир")
        #expect(rules("мир", "дом 5") == " мир")
        #expect(rules("мир", "дом5") == " мир")
        #expect(rules("мир", "привет,") == " мир")
        #expect(rules("мир", "(привет)") == " мир")
        #expect(rules("мир", "«привет»") == " мир")
        #expect(rules("Мир", "Привет.") == " Мир")
    }

    @Test func noSpaceAfterSpaceOpenersAndNewlines() {
        #expect(rules("мир", "привет ") == "мир")
        #expect(rules("мир", "привет\n") == "Мир")
        #expect(rules("мир", "(") == "мир")
        #expect(rules("мир", "«") == "мир")
        #expect(rules("мир", "\"") == "мир")
        #expect(rules("мир", "") == "Мир")
    }

    @Test func noSpaceBeforePunctuationInTheText() {
        #expect(rules(", да", "привет") == ", да")
        #expect(rules(".", "привет") == ".")
    }

    @Test func unknownContextAddsNoSpace() {
        #expect(rules("мир", nil) == "мир")
    }

    // MARK: All together

    @Test func rulesWorkTogether() {
        #expect(rules("Э-э, перекей, ну, работает", "Говорят, ") == "Perekey, работает")
        #expect(rules("Um, the Perekey app", "I use") == " the Perekey app")
        #expect(rules("Ну, перекей и open ai", "") == "Perekey и OpenAI")
        #expect(rules("Давай, как бы, начнём", "Хорошо.") == " Давай, начнём")
    }

    // MARK: Whisper prompt

    @Test func promptListsTheTargetsOnce() {
        let list = [DictionaryEntry(from: "перекей", to: "Perekey"), DictionaryEntry(from: "перикей", to: "Perekey"),
                    DictionaryEntry(from: "ай фон", to: "iPhone")]
        #expect(TextRules.whisperPrompt(dictionary: list) == "Perekey, iPhone")
        #expect(TextRules.whisperPrompt(dictionary: []) == "")
    }

    @Test func promptStaysInTheLimitWithWholeTerms() {
        let many = (0..<100).map { DictionaryEntry(from: "w\($0)", to: "Термин\($0)") }
        let prompt = TextRules.whisperPrompt(dictionary: many, limit: 50)
        #expect(prompt.count <= 50)
        #expect(prompt.hasPrefix("Термин0, Термин1"))
        #expect(prompt.split(separator: ",").allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Термин") })
    }
}
