// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyVoiceCore
import Testing

struct HallucinationFilterTests {
    @Test(arguments: [
        "Субтитры сделал DimaTorzok",
        "Субтитры сделал DimaTorzok.",
        "  Продолжение следует...  ",
        "Продолжение следует…",
        "Thank you for watching!",
        "Thanks for watching.",
        "Спасибо за просмотр!",
        "Please subscribe.",
        "Редактор субтитров А.Семкин Корректор А.Егорова",
        "Субтитры сделаны сообществом Amara.org",
        "Субтитры подготовил Игорь Негода",
        "Subtitles by Amara.org",
        "Подписывайтесь на канал!",
        // A sign-off as the whole text, once the credits after it went.
        "Продолжение следует. Субтитры сделал DimaTorzok",
        "",
        "   ",
    ])
    func madeUpAlone(_ text: String) {
        #expect(HallucinationFilter.clean(text) == "")
        #expect(HallucinationFilter.clean(text, signOffTails: true) == "")
    }

    @Test(arguments: [
        ("Отправь отчёт. Субтитры сделал DimaTorzok", "Отправь отчёт."),
        ("Hello there. Subtitles by Amara.org", "Hello there."),
        (" Привет. ", "Привет."),
        ("Купи хлеб. Редактор субтитров А.Семкин Корректор А.Егорова", "Купи хлеб."),
    ])
    func creditsGoFromAnyTail(_ text: String, _ expected: String) {
        #expect(HallucinationFilter.clean(text) == expected)
        #expect(HallucinationFilter.clean(text, signOffTails: true) == expected)
    }

    @Test(arguments: [
        ("Привет, как дела? Продолжение следует...", "Привет, как дела?"),
        ("Отправь отчёт! Продолжение следует... Субтитры сделал DimaTorzok", "Отправь отчёт!"),
        ("Hello there. Thank you for watching.", "Hello there."),
        ("Пока. Субтитры создавал DimaTorzok. Продолжение следует...", "Пока."),
    ])
    func signOffsGoFromWhispersTail(_ text: String, _ expected: String) {
        #expect(HallucinationFilter.clean(text, signOffTails: true) == expected)
    }

    @Test(arguments: [
        // A sign-off after speech is speech to a model that does not make them up.
        "Привет, как дела? Продолжение следует...",
        "Серия закончилась. Продолжение следует.",
        "Хорошего вечера. Спасибо за просмотр!",
        "Hello there. Thank you for watching.",
        "That is all for today. Please subscribe.",
        // The same words inside a sentence are speech.
        "Он сказал, что продолжение следует, и ушёл.",
        "Продолжение следует в понедельник.",
        "Спасибо за просмотр презентации, коллеги.",
        "Thank you for watching the kids yesterday.",
        "Субтитры сделал мой брат для всего фильма вчера вечером.",
        // Credits without a name or a site after them.
        "Редактор субтитров не открывается.",
        "Субтитры сделаны для всех серий.",
        "Субтитры сделал мой брат.",
        "Редактор субтитров сломался, корректор тоже.",
        // A sign-off first, speech after it: speech stays whole.
        "Продолжение следует. Завтра обсудим детали.",
        "Включи субтитры.",
        "Открой pull request в main.",
        "Спасибо.",
        "Thank you.",
    ])
    func speechStays(_ text: String) {
        #expect(HallucinationFilter.clean(text) == text)
    }

    @Test func whisperKeepsSpeechToo() {
        for text in ["Он сказал, что продолжение следует, и ушёл.", "Субтитры сделаны для всех серий.",
                     "Редактор субтитров не открывается.", "Продолжение следует. Завтра обсудим детали."]
        {
            #expect(HallucinationFilter.clean(text, signOffTails: true) == text)
        }
    }

    @Test func longSpeechIsReadFromTheEnd() {
        let speech = String(repeating: "Это длинная фраза о работе. ", count: 2000)
        #expect(HallucinationFilter.clean(speech + "Субтитры сделал DimaTorzok")
            == String(speech.dropLast()))
    }

    @Test func words() {
        let word = HallucinationFilter.Word("«Ёлка»,")
        #expect(word.normalized == "елка")
        #expect(word.looksLikeName)
        #expect(!HallucinationFilter.Word("серий.").looksLikeName)
        #expect(HallucinationFilter.Word("Amara.org").looksLikeName)
        #expect(HallucinationFilter.Word("dimatorzok").looksLikeName)
        #expect(HallucinationFilter.Word("—").normalized.isEmpty)
    }

    @Test func sentenceStartsSkipInitials() {
        let text = "Редактор А.Семкин. Корректор"
        let starts = HallucinationFilter.sentenceStarts(text).map { String(text[$0...]) }
        #expect(starts == [text, "Корректор"])
    }
}
