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
        "Редактор субтитров А.Семкин Корректор А.Егорова",
        "Субтитры сделаны сообществом Amara.org",
        "Субтитры создавал DimaTorzok. Продолжение следует...",
        "Подписывайтесь на канал!",
        "Субтитры сделал DimaTorzok Продолжение следует",
        "",
        "   ",
    ])
    func madeUpAlone(_ text: String) {
        #expect(HallucinationFilter.clean(text) == "")
    }

    @Test(arguments: [
        ("Привет, как дела? Продолжение следует...", "Привет, как дела?"),
        ("Отправь отчёт. Субтитры сделал DimaTorzok", "Отправь отчёт."),
        ("Отправь отчёт! Продолжение следует... Субтитры сделал DimaTorzok", "Отправь отчёт!"),
        ("Hello there. Thank you for watching.", "Hello there."),
        (" Привет. ", "Привет."),
    ])
    func madeUpTail(_ text: String, _ expected: String) {
        #expect(HallucinationFilter.clean(text) == expected)
    }

    @Test(arguments: [
        // The same words inside a sentence are speech.
        "Он сказал, что продолжение следует, и ушёл.",
        "Продолжение следует в понедельник.",
        "Спасибо за просмотр презентации, коллеги.",
        "Thank you for watching the kids yesterday.",
        "Субтитры сделал мой брат для всего фильма вчера вечером.",
        // A hallucination phrase first, speech after it: speech stays whole.
        "Продолжение следует. Завтра обсудим детали.",
        "Включи субтитры.",
        "Открой pull request в main.",
        "Спасибо.",
        "Thank you.",
    ])
    func speechStays(_ text: String) {
        #expect(HallucinationFilter.clean(text) == text)
    }

    @Test func normalizes() {
        #expect(HallucinationFilter.normalized("Субтитры: «Ёлка», A.Семкин!") == "субтитры елка a семкин")
    }

    @Test func sentenceStartsSkipInitials() {
        let text = "Редактор А.Семкин. Корректор"
        let starts = HallucinationFilter.sentenceStarts(text).map { String(text[$0...]) }
        #expect(starts == [text, "Корректор"])
    }
}
