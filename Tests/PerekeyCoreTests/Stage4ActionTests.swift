// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

private let en = Fixture.abc.id
private let ru = Fixture.russian.id

private func settings(_ action: HotkeyAction) -> Settings {
    Settings(hotkeys: [HotkeyBinding(.modifiers(.option, taps: .single), action: action)])
}

@Suite struct CaseCycleTests {
    @Test func cycleWalksLowerTitleUpper() {
        #expect(TextCase.next(after: "hello") == "Hello")
        #expect(TextCase.next(after: "Hello") == "HELLO")
        #expect(TextCase.next(after: "HELLO") == "hello")
        #expect(TextCase.next(after: "привет") == "Привет")
        #expect(TextCase.next(after: "Привет") == "ПРИВЕТ")
        #expect(TextCase.next(after: "ПРИВЕТ") == "привет")
    }

    @Test func mixedCaseIsLoweredFirst() {
        #expect(TextCase.next(after: "iPhone") == "iphone")
        #expect(TextCase.next(after: "пРИВЕТ") == "привет")
    }

    @Test func oneLetterSkipsEqualTitle() {
        #expect(TextCase.next(after: "a") == "A")
        #expect(TextCase.next(after: "A") == "a")
    }

    @Test func titleCapitalizesEveryWord() {
        #expect(TextCase.next(after: "hello big world") == "Hello Big World")
        #expect(TextCase.next(after: "don't stop") == "Don't Stop")
    }

    @Test func noLettersNoChange() {
        #expect(TextCase.next(after: "123 !?") == nil)
        #expect(TextCase.next(after: "") == nil)
    }

    @Test func charactersKeepTheirCount() {
        // ß has no single-character capital: it stays, keys keep matching.
        #expect(TextCase.upper.apply(to: "straße") == "STRAßE")
    }
}

@Suite struct TransliterationTests {
    @Test func gostTable() {
        #expect(Transliteration.convert("привет мир") == "privet mir")
        #expect(Transliteration.convert("Щётка, ёжик, жук") == "Shhyotka, yozhik, zhuk")
        #expect(Transliteration.convert("съезд, объект, ёлка") == "s''ezd, ob''ekt, yolka")
        #expect(Transliteration.convert("цех, чай, ты, этот") == "cex, chaj, ty', e`tot")
        #expect(Transliteration.convert("юля яблоко") == "yulya yabloko")
    }

    @Test func capitalsFollowTheirNeighbors() {
        #expect(Transliteration.convert("Жук") == "Zhuk")
        #expect(Transliteration.convert("ЖУК") == "ZHUK")
        #expect(Transliteration.convert("ЩИ") == "SHHI")
        #expect(Transliteration.convert("Ж") == "Zh")
    }

    @Test func latinGoesToCyrillicLongestFirst() {
        #expect(Transliteration.convert("shhuka") == "щука")
        #expect(Transliteration.convert("Zhuk") == "Жук")
        #expect(Transliteration.convert("ZHUK") == "ЖУК")
        #expect(Transliteration.convert("yozh, yulya") == "ёж, юля")
    }

    @Test func directionFollowsTheMajorityScript() {
        #expect(Transliteration.direction(of: "привет world") == .toLatin)
        #expect(Transliteration.direction(of: "privet мир world") == .toCyrillic)
        #expect(Transliteration.direction(of: "123") == nil)
        #expect(Transliteration.convert("123 !?") == nil)
    }

    @Test func alphabetRoundTrips() {
        let alphabet = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
        let words = [alphabet, alphabet.uppercased().replacingOccurrences(of: "Ъ", with: "ъ")
            .replacingOccurrences(of: "Ь", with: "ь"),
            "Привет, Мир! Съешь ещё этих мягких французских булок, да выпей чаю.",
            "ЖУК ЩУКА Жук Щука жук щука", "Ёлка Юля Яблоко", "объём подъезд", "льдина", "ЦЕХ чехол",
            "ЖУКИ", "ХХХ", "сш сх зх кх тс"]
        for word in words {
            let latin = Transliteration.convert(word, .toLatin)
            #expect(Transliteration.convert(latin, .toCyrillic) == word, "\(word) → \(latin)")
        }
    }

    @Test func latinRoundTrips() {
        for word in ["privet mir", "Zhuk", "shhuka", "yozhik", "ty' e`to", "s''ezd", "cirk"] {
            let cyrillic = Transliteration.convert(word, .toCyrillic)
            #expect(Transliteration.convert(cyrillic, .toLatin) == word, "\(word) → \(cyrillic)")
        }
    }
}

@Suite struct ChangeCaseTests {
    @Test func lastWordCyclesWithoutLeavingTheLayout() throws {
        var kb = Keyboard(settings(.changeCase))
        kb.type("hello", in: Fixture.abc)
        let output = kb.tapOption()
        #expect(!output.effects.contains { if case .selectLayout = $0 { true } else { false } })
        let retype = try #require(output.retype)
        #expect(retype.deleteCount == 5)
        #expect(retype.text == "Hello")
        #expect(retype.expected == "hello")
        #expect(retype.target == en)
        #expect(retype.keys.first?.stroke == KeyStroke(Fixture.abc.stroke(for: "h")!.keyCode, .shift))
        #expect(retype.keys.dropFirst().allSatisfy { $0.stroke.modifiers.isEmpty })
        #expect(kb.machine.isHolding)
        #expect(kb.completeRetype(retype) == [.releaseHeld])
    }

    @Test func repeatedPressesCycleAndBufferStaysUsable() throws {
        var kb = Keyboard(settings(.changeCase))
        kb.type("hello", in: Fixture.abc)
        var texts: [String] = []
        for _ in 0..<4 {
            let retype = try #require(kb.tapOption().retype)
            texts.append(retype.text)
            #expect(retype.deleteCount == 5)
            kb.completeRetype(retype)
        }
        #expect(texts == ["Hello", "HELLO", "hello", "Hello"])
        // Typing goes on in the same word.
        kb.type("!", in: Fixture.abc)
        #expect(try #require(kb.tapOption().retype).deleteCount == 6)
    }

    @Test func russianWordAndTrailingSpace() throws {
        var kb = Keyboard(settings(.changeCase), current: ru)
        kb.type("привет ", in: Fixture.russian)
        let retype = try #require(kb.tapOption().retype)
        #expect(retype.text == "Привет ")
        #expect(retype.deleteCount == 7)
        #expect(retype.target == ru)
    }

    @Test func wordTypedInAnotherLayoutIsRefused() {
        var kb = Keyboard(settings(.changeCase))
        kb.type("ghbdtn", in: Fixture.abc)
        kb.send(.layoutChanged(ru))
        #expect(kb.tapOption().effects == [.refused(.unsupportedLayout)])
    }

    @Test func passwordFieldIsRefused() {
        var kb = Keyboard(settings(.changeCase))
        kb.send(.focusChanged(Focus(bundleID: "x", isSecureField: true)))
        #expect(kb.tapOption().effects == [.refused(.secureField)])
    }

    @Test func wordWithoutLettersIsRefused() {
        var kb = Keyboard(settings(.changeCase))
        kb.type("123", in: Fixture.abc)
        #expect(kb.tapOption().effects == [.refused(.unconvertibleWord)])
        #expect(!kb.machine.isHolding)
    }

    @Test func cancelledRetypeReleasesWithoutLayoutChange() throws {
        var kb = Keyboard(settings(.changeCase))
        kb.type("hello", in: Fixture.abc)
        let retype = try #require(kb.tapOption().retype)
        #expect(kb.send(.retypeCancelled(seq: retype.seq)).effects == [.releaseHeld])
        #expect(kb.machine.currentLayout == en)
    }

    @Test func selectionGoesThroughTheSameCycle() throws {
        var kb = Keyboard(settings(.changeCase))
        let seq = try #require(kb.tapOption().selectionSeq)
        let output = kb.send(.selectionRead(seq: seq, text: "hello big world"))
        let retype = try #require(output.retype)
        #expect(retype.deleteCount == 0)
        #expect(retype.text == "Hello Big World")
        #expect(retype.expected == "hello big world")
        #expect(retype.target == en)
        #expect(!output.effects.contains { if case .selectLayout = $0 { true } else { false } })
        #expect(kb.completeRetype(retype, confirm: false) == [.releaseHeld])
    }

    @Test func russianSelectionIsTypedInRussianLayout() throws {
        var kb = Keyboard(settings(.changeCase))
        let seq = try #require(kb.tapOption().selectionSeq)
        let output = kb.send(.selectionRead(seq: seq, text: "ПРИВЕТ"))
        #expect(output.effects.first == .selectLayout(ru))
        #expect(try #require(output.retype).text == "привет")
    }

    @Test func selectionWithoutLettersIsRefused() throws {
        var kb = Keyboard(settings(.changeCase))
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.selectionRead(seq: seq, text: "123")).effects == [.refused(.unsupportedSelection), .releaseHeld])
        #expect(!kb.machine.isHolding)
    }
}

@Suite struct TransliterateActionTests {
    @Test func cyrillicSelectionIsTypedInLatin() throws {
        var kb = Keyboard(settings(.transliterate), current: ru)
        let seq = try #require(kb.tapOption().selectionSeq)
        let output = kb.send(.selectionRead(seq: seq, text: "Привет, мир"))
        #expect(output.effects.first == .selectLayout(en))
        let retype = try #require(output.retype)
        #expect(retype.text == "Privet, mir")
        #expect(retype.expected == "Привет, мир")
        #expect(retype.target == en)
        #expect(retype.deleteCount == 0)
        #expect(kb.completeRetype(retype) == [.releaseHeld])
    }

    @Test func latinSelectionIsTypedInRussian() throws {
        var kb = Keyboard(settings(.transliterate))
        let seq = try #require(kb.tapOption().selectionSeq)
        let output = kb.send(.selectionRead(seq: seq, text: "Zhuk"))
        #expect(output.effects.first == .selectLayout(ru))
        #expect(try #require(output.retype).text == "Жук")
    }

    @Test func typedWordIsNotUsed() throws {
        // Transliteration works on a selection only.
        var kb = Keyboard(settings(.transliterate))
        kb.type("hello", in: Fixture.abc)
        #expect(kb.tapOption().startsSelectionConversion)
    }

    @Test func nothingToConvertIsRefused() throws {
        var kb = Keyboard(settings(.transliterate))
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.selectionRead(seq: seq, text: "123")).effects == [.refused(.unsupportedSelection), .releaseHeld])
    }

    @Test func nothingSelectedIsRefused() throws {
        var kb = Keyboard(settings(.transliterate))
        let seq = try #require(kb.tapOption().selectionSeq)
        #expect(kb.send(.selectionRead(seq: seq, text: "")).effects == [.refused(.nothingSelected), .releaseHeld])
    }
}

@Suite struct PastePlainActionTests {
    private let v: UInt16 = 9

    @Test func keyTriggerAsksForAPlainPaste() {
        var kb = Keyboard(Settings(hotkeys: [HotkeyBinding(.key(keyCode: v, modifiers: [.control, .option]),
                                                           action: .pastePlain)]))
        kb.time += 1
        let output = kb.send(.key(KeyEvent(.down, keyCode: v, flags: EventFlags.control | EventFlags.option),
                                  time: kb.time))
        #expect(output == Output(.drop, [.pastePlain]))
        #expect(!kb.machine.isHolding, "no fence: the paste is not a retype")
    }

    @Test func modifierOnlyTriggerIsIgnored() {
        var kb = Keyboard(settings(.pastePlain))
        #expect(kb.tapOption().effects.isEmpty)
        #expect(!HotkeyAction.pastePlain.acceptsModifierOnlyTrigger)
        #expect(HotkeyAction.changeCase.acceptsModifierOnlyTrigger)
    }

    @Test func offByDefault() {
        for preset in HotkeyPreset.allCases {
            let actions = preset.bindings.map(\.action)
            #expect(!actions.contains(.pastePlain) && !actions.contains(.changeCase) && !actions.contains(.transliterate))
        }
    }
}

@Suite struct SoundSettingsTests {
    @Test func offByDefaultAndSurviveRoundTrip() throws {
        var settings = AppSettings()
        #expect(!settings.layoutSound.isOn && !settings.correctionSound.isOn)
        settings.layoutSound = SoundSetting(isOn: true, name: "Pop")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.layoutSound == SoundSetting(isOn: true, name: "Pop"))
        #expect(!decoded.correctionSound.isOn)
    }

    @Test func oldFilesLoadWithDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":false}"#.utf8))
        #expect(decoded.layoutSound == .layoutSwitch && decoded.correctionSound == .correction)
    }
}

@Suite struct FalseSwitchReportTests {
    private func query(_ report: FalseSwitchReport) throws -> [String: String] {
        let components = try #require(URLComponents(url: report.url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/tlgnkl/perekey/issues/new")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func fillsTheTemplateFields() throws {
        let report = FalseSwitchReport(typed: "ghbdtn", did: "Changed to привет", mode: .automatic,
                                       layouts: ["ABC", "Russian"], version: "Perekey 0.1 (1), macOS 14.5")
        let items = try query(report)
        #expect(items["template"] == "false-switch.yml")
        #expect(items["typed"] == "ghbdtn")
        #expect(items["did"] == "Changed to привет")
        #expect(items["layouts"] == "ABC, Russian")
        #expect(items["mode"] == "Automatic")
        #expect(items["version"] == "Perekey 0.1 (1), macOS 14.5")
    }

    @Test func wordIsOnlyThereIfKept() throws {
        let without = FalseSwitchReport(typed: "", layouts: ["ABC"])
        #expect(try query(without)["typed"] == nil)
        #expect(!without.fields.contains { $0.id == "typed" })
        #expect(!without.url.absoluteString.contains("typed"))
        #expect(FalseSwitchReport(typed: "   ").fields.allSatisfy { $0.id != "typed" })
    }

    @Test func fieldsAreExactlyWhatTheLinkCarries() throws {
        let report = FalseSwitchReport(typed: "a&b=c#d+e", did: "x", layouts: ["ABC"], version: "v")
        let items = try query(report)
        #expect(items["typed"] == "a&b=c#d+e", "reserved characters cannot change the link")
        for field in report.fields { #expect(items[field.id] == field.value) }
        #expect(Set(items.keys) == Set(report.fields.map(\.id)).union(["template"]))
    }

    @Test func longWordIsCut() {
        let report = FalseSwitchReport(typed: String(repeating: "я", count: 500))
        #expect(report.typed.count == FalseSwitchReport.maxWordLength)
    }

    @Test func layoutNames() {
        #expect(FalseSwitchReport.layoutName("com.apple.keylayout.Russian") == "Russian")
        #expect(FalseSwitchReport.layoutName("org.example.Other") == "org.example.Other")
    }
}
