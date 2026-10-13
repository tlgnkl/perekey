// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
@testable import PerekeyVoiceCore
import Testing

/// A layout whose keys type `alphabet`, one letter a key.
private func layout(_ id: String, _ language: String, _ alphabet: String) -> LayoutMap {
    var table: [KeyStroke: String] = [:]
    for (index, letter) in alphabet.enumerated() {
        table[KeyStroke(UInt16(index))] = String(letter)
    }
    return LayoutMap(id: LayoutID(id), language: language, table: table)
}

private let russian = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
private let ukrainian = "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"
private let latin = "abcdefghijklmnopqrstuvwxyz"
private let ru = layout("ru", "ru", russian)
private let uk = layout("uk", "uk", ukrainian)
private let en = layout("en", "en", latin)

struct DictationLanguageTests {
    @Test func russianPhraseEndingInEnglish() {
        let text = "Сделай коммит и отправь изменения в main"
        #expect(DictationLanguage.dominant(in: text, layouts: [en, ru], model: nil) == "ru")
        #expect(DictationLanguage.layout(after: text, layouts: [en, ru], current: en.id, model: nil) == ru.id)
    }

    @Test func noClearLeadKeepsTheLayout() {
        // Two Russian words, three English: neither has two thirds.
        let text = "открой pull request в main"
        #expect(DictationLanguage.dominant(in: text, layouts: [en, ru], model: nil) == nil)
        #expect(DictationLanguage.layout(after: text, layouts: [en, ru], current: en.id, model: nil) == nil)
        #expect(DictationLanguage.layout(after: text, layouts: [en, ru], current: ru.id, model: nil) == nil)
    }

    @Test func wordsCountNotLetters() {
        // Two long English words, four short Russian ones: Russian leads by words.
        #expect(DictationLanguage.dominant(in: "я и ты в internationalization documentation", layouts: [en, ru],
                                           model: nil) == "ru")
    }

    @Test func englishPhrase() {
        let text = "Open the pull request in main, please."
        #expect(DictationLanguage.layout(after: text, layouts: [en, ru], current: ru.id, model: nil) == en.id)
    }

    @Test func alreadyThere() {
        #expect(DictationLanguage.layout(after: "Привет всем", layouts: [en, ru], current: ru.id, model: nil) == nil)
    }

    @Test func nothingToChoose() {
        #expect(DictationLanguage.layout(after: "Привет", layouts: [ru], current: nil, model: nil) == nil)
        #expect(DictationLanguage.layout(after: "123 — 456", layouts: [en, ru], current: en.id, model: nil) == nil)
        // As many letters in each: no switch.
        #expect(DictationLanguage.dominant(in: "дом hey", layouts: [en, ru], model: nil) == nil)
    }

    @Test func twoCyrillicLayoutsNeedTheModel() throws {
        // "привіт" only Ukrainian types; "сказав" both, so without a model it counts for none.
        #expect(DictationLanguage.dominant(in: "Привіт, він сказав", layouts: [ru, uk], model: nil) == "uk")
        #expect(DictationLanguage.language(of: "сказав", layouts: [ru, uk], model: nil) == nil)

        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: russian)
        builder.addLanguage("uk", alphabet: ukrainian)
        for word in ["сказал", "привет", "он", "это", "дом", "сделал"] {
            _ = builder.addForm(word, language: "ru", rank: 10, weight: 100)
        }
        for word in ["сказав", "привіт", "він", "це", "дім", "зробив"] {
            _ = builder.addForm(word, language: "uk", rank: 10, weight: 100)
        }
        let model = try LanguageModel(bytes: builder.build())
        #expect(DictationLanguage.language(of: "сказав", layouts: [ru, uk], model: model) == "uk")
        #expect(DictationLanguage.language(of: "сказал", layouts: [ru, uk], model: model) == "ru")
        #expect(DictationLanguage.dominant(in: "Он сказал: это дом", layouts: [ru, uk, en], model: model) == "ru")
    }
}
