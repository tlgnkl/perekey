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
        #expect(ModelStore.classifier(bundle: Bundle(for: Marker.self)) == nil)
    }

    private final class Marker {}
}
