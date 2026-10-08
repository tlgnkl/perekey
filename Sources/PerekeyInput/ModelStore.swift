// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore

/// The language model shipped in the app bundle: `Contents/Resources/perekey.model`,
/// put there by scripts/bundle.sh. Loaded once on the main thread; the
/// `Classifier` is `Sendable` and goes to the event tap thread as a value.
public enum ModelStore {
    public static let resourceName = "perekey"
    public static let resourceExtension = "model"

    private static let log = Logger(subsystem: "app.perekey", category: "model")

    /// The classifier over the bundled model, or `nil` with the reason logged:
    /// no model in the bundle, or a file the reader rejects.
    public static func classifier(bundle: Bundle = .main, options: Classifier.Options = .init()) -> Classifier? {
        model(bundle: bundle).map { Classifier(model: $0, options: options) }
    }

    /// The bundled model, mapped from disk.
    public static func model(bundle: Bundle = .main) -> LanguageModel? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            log.error("no \(resourceName).\(resourceExtension) in \(bundle.bundlePath, privacy: .public): automatic switching is off")
            return nil
        }
        return model(at: url.path)
    }

    /// A model file anywhere, for tests and tools.
    public static func model(at path: String) -> LanguageModel? {
        do {
            let model = try ModelFile.load(path)
            log.info("model \(path, privacy: .public): \(model.languages.map(\.code).joined(separator: ", "), privacy: .public), \(model.bytes.count / 1024) KB")
            return model
        } catch {
            log.error("model \(path, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
