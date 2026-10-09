// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

struct ModelStoreTests {
    static func fixture() -> [UInt8] {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
        builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
        builder.addForm("привет", language: "ru", rank: 200, weight: 100)
        builder.addForm("hello", language: "en", rank: 200, weight: 100)
        return builder.build()
    }

    @Test func loadsAModelFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("perekey-\(UUID()).model").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(Self.fixture()).write(to: URL(fileURLWithPath: path))
        let model = try #require(ModelStore.model(at: path))
        #expect(model.languages.map(\.code) == ["ru", "en"])
        let classifier = Classifier(model: model)
        #expect(classifier.options.threshold == Classifier.Options().threshold)
    }

    @Test func missingOrCorruptFilesGiveNil() throws {
        #expect(ModelStore.model(at: "/nonexistent/perekey.model") == nil)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("perekey-\(UUID()).model").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var bytes = Self.fixture()
        bytes[bytes.count - 1] ^= 0xFF
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        #expect(ModelStore.model(at: path) == nil)
        // The test bundle has no model resource.
        #expect(ModelStore.classifier(languages: ["ru", "en"], bundle: Bundle(for: Marker.self)) == nil)
    }

    static func file(_ language: String, alphabet: String, word: String) -> [UInt8] {
        var builder = ModelBuilder()
        builder.addLanguage(language, alphabet: alphabet)
        builder.addForm(word, language: language, rank: 200, weight: 100)
        return builder.build()
    }

    /// A bundle directory with `ru.pklm`, `en.pklm` and `uk.pklm`.
    static func bundle() throws -> (Bundle, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("perekey-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(file("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-", word: "привет"))
            .write(to: directory.appendingPathComponent("ru.pklm"))
        try Data(file("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-", word: "hello"))
            .write(to: directory.appendingPathComponent("en.pklm"))
        try Data(file("uk", alphabet: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя'-", word: "привіт"))
            .write(to: directory.appendingPathComponent("uk.pklm"))
        return (try #require(Bundle(path: directory.path)), directory)
    }

    @Test func mapsOnlyTheLanguagesAskedFor() throws {
        let (bundle, directory) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        let english = try #require(ModelStore.model(languages: ["en"], bundle: bundle))
        #expect(english.codes == ["en"])
        // A Russian layout comes: the English file is kept, the Russian one mapped.
        let both = try #require(ModelStore.model(languages: ["ru", "en"], reusing: english, bundle: bundle))
        #expect(both.codes == ["ru", "en"])
        #expect(both.byteCount > english.byteCount)
        // It goes again: nothing of it stays mapped.
        let again = try #require(ModelStore.model(languages: ["en"], reusing: both, bundle: bundle))
        #expect(again.codes == ["en"])
        #expect(again.byteCount == english.byteCount)
        // A language without a file is skipped; none at all gives nil.
        #expect(ModelStore.model(languages: ["en", "de"], bundle: bundle)?.codes == ["en"])
        #expect(ModelStore.model(languages: ["de"], bundle: bundle) == nil)
        // uk.pklm loads, though the app does not switch Ukrainian yet.
        #expect(ModelStore.model(languages: ["uk"], bundle: bundle)?.codes == ["uk"])
    }

    @Test func theAppMapsOnlyEnabledLanguages() {
        let layouts = [("ABC", "en"), ("Russian", "ru"), ("Ukrainian", "uk"), ("Byelorussian", "be"), ("Kazakh", "kk"), ("Emoji", nil)].map { id, language in
            LayoutMap(id: LayoutID(rawValue: id), language: language, table: [:])
        }
        let shipped: Set<String> = ["ru", "en", "uk", "be"]
        #expect(ModelStore.languages(of: layouts, enabled: shipped) == shipped, "Kazakh is built but not shipped")
        #expect(ModelStore.languages(of: Array(layouts.prefix(1)), enabled: shipped) == ["en"],
                "no Russian layout, no Russian file")
        #expect(ModelStore.languages(of: layouts, enabled: ["ru", "en"]) == ["ru", "en"])
    }

    @Test func theAppEnablesTheFilesTheBundleCarries() throws {
        let (bundle, directory) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ModelStore.bundledLanguages(in: bundle) == ["ru", "en", "uk"])
        #expect(ModelStore.bundledLanguages(in: Bundle(for: Marker.self)).isEmpty)
    }

    /// data/languages is the one list of shipped languages: every one has a
    /// recorded model hash.
    @Test func theShippedLanguagesHaveRecordedModels() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let languages = try String(contentsOf: root.appendingPathComponent("data/languages"), encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.map(String.init)
        let hashes = try String(contentsOf: root.appendingPathComponent("data/model.sha256"), encoding: .utf8)
        #expect(languages == ["ru", "en", "uk", "be"])
        for language in languages { #expect(hashes.contains("  \(language).pklm"), "\(language)") }
    }

    private final class Marker {}
}
