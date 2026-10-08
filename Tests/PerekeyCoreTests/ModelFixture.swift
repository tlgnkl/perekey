// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyCore

/// A tiny language model built in the test: a few dozen words per language.
/// Enough for the golden cases; the real model needs the data cache.
enum ModelFixture {
    static let russian: [(String, UInt8)] = [
        ("а", 240), ("и", 240), ("в", 240), ("не", 235), ("на", 230), ("я", 225), ("что", 225), ("это", 220),
        ("он", 215), ("как", 210), ("но", 205), ("привет", 200), ("мир", 195), ("будет", 195), ("хорошо", 195),
        ("выбор", 170), ("ёлка", 150), ("ожидание", 150), ("спасибо", 190), ("пожалуйста", 180),
        ("работа", 185), ("время", 190), ("человек", 190), ("день", 190), ("слово", 180), ("дом", 185),
        ("город", 180), ("вопрос", 175), ("ответ", 175), ("сегодня", 185), ("завтра", 175), ("можно", 190),
        ("нужно", 185), ("просто", 185), ("очень", 190), ("только", 195), ("если", 195), ("когда", 190),
        ("потом", 170), ("здесь", 175), ("теперь", 175), ("делать", 180), ("сказать", 180), ("думать", 170),
        ("знать", 175), ("видеть", 170), ("хотеть", 170), ("письмо", 160), ("книга", 165), ("окно", 160),
        ("машина", 165), ("дорога", 160), ("вода", 165), ("земля", 160), ("небо", 155), ("солнце", 155),
        ("ночь", 165), ("утро", 160), ("вечер", 160), ("неделя", 160), ("месяц", 160), ("год", 185),
        ("программа", 165), ("компьютер", 160), ("телефон", 160), ("клавиатура", 140), ("раскладка", 130),
        ("переключение", 120), ("кто-то", 160), ("что-то", 170), ("почему", 175), ("потому", 170),
    ]

    static let english: [(String, UInt8)] = [
        ("a", 240), ("i", 235), ("the", 245), ("to", 240), ("and", 240), ("of", 240), ("in", 235), ("is", 235),
        ("it", 230), ("you", 230), ("that", 230), ("he", 225), ("was", 225), ("for", 225), ("on", 225),
        ("are", 220), ("with", 220), ("as", 220), ("his", 215), ("they", 215), ("be", 220), ("at", 220),
        ("one", 215), ("have", 220), ("this", 220), ("from", 215), ("or", 215), ("had", 210), ("by", 215),
        ("hot", 180), ("word", 185), ("but", 220), ("what", 215), ("some", 210), ("we", 220), ("can", 215),
        ("out", 210), ("other", 205), ("were", 210), ("all", 215), ("there", 210), ("when", 210), ("up", 210),
        ("use", 195), ("your", 215), ("how", 210), ("said", 200), ("an", 215), ("each", 195), ("she", 210),
        ("which", 205), ("do", 215), ("their", 205), ("time", 210), ("if", 215), ("will", 215), ("way", 200),
        ("about", 210), ("many", 200), ("then", 205), ("them", 205), ("write", 185), ("would", 210),
        ("like", 210), ("so", 215), ("these", 200), ("her", 210), ("long", 195), ("make", 200), ("thing", 195),
        ("see", 200), ("him", 205), ("two", 200), ("has", 210), ("look", 195), ("more", 210), ("day", 200),
        ("could", 205), ("go", 205), ("come", 200), ("did", 205), ("number", 190), ("sound", 180), ("no", 215),
        ("most", 200), ("people", 205), ("my", 215), ("over", 200), ("know", 205), ("water", 190),
        ("than", 205), ("call", 190), ("first", 200), ("who", 210), ("may", 200), ("down", 200), ("side", 185),
        ("been", 205), ("now", 210), ("find", 195), ("hello", 190), ("world", 195), ("code", 185),
        ("keyboard", 160), ("layout", 160), ("don't", 200), ("world's", 150), ("print", 170), ("let", 190),
        ("func", 120), ("var", 140), ("return", 170), ("switch", 170), ("iphone", 170),
    ]

    static let bytes: [UInt8] = {
        var builder = ModelBuilder()
        builder.meta = "fixture"
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        for (word, rank) in russian {
            builder.addForm(word, language: "ru", rank: rank, weight: Double(rank))
        }
        for (word, rank) in english {
            builder.addForm(word, language: "en", rank: rank, weight: Double(rank))
        }
        for word in ["iPhone", "Wi-Fi", "ГОСТ"] { builder.addKeep(word) }
        return builder.build()
    }()

    static let model = try! LanguageModel(bytes: bytes)
}
