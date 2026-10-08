// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore

/// The language model shipped in the app bundle: a file per language,
/// `Contents/Resources/<language>.pklm`, put there by scripts/bundle.sh.
/// Only the languages of the installed layouts are mapped; when the layouts
/// change, the app asks again and the files of removed languages go with the
/// last model that holds them. Loaded on the main thread; the `Classifier`
/// is `Sendable` and goes to the event tap thread as a value.
public enum ModelStore {
    private static let log = Logger(subsystem: "app.perekey", category: "model")

    /// The languages the app switches between. A model file is all the core
    /// needs to switch a pair, so a language joins here only with its own
    /// task: Ukrainian with stage 8, task 1 (ru ↔ uk never switches
    /// automatically, docs/PLAN.md). `uk.pklm` is built and tested already.
    public static let enabledLanguages: Set<String> = ["ru", "en"]

    /// The enabled languages the model needs for these layouts.
    public static func languages(of layouts: [LayoutMap], enabled: Set<String> = enabledLanguages) -> Set<String> {
        Set(layouts.compactMap(\.language)).intersection(enabled)
    }

    /// The classifier over the bundled files of `languages`, or `nil` with the
    /// reason logged: no file for any of them, or files the reader rejects.
    public static func classifier(languages: Set<String>, bundle: Bundle = .main,
                                  options: Classifier.Options = .init()) -> Classifier?
    {
        model(languages: languages, bundle: bundle).map { Classifier(model: $0, options: options) }
    }

    /// The bundled files of `languages` as one model. The files of `current`
    /// that are still wanted are kept as they are, mapped once; a language
    /// without a file is skipped (Perekey has no model for it).
    public static func model(languages: Set<String>, reusing current: LanguageModel? = nil,
                             bundle: Bundle = .main) -> LanguageModel?
    {
        let kept = current?.keeping(languages: languages)
        var models = kept.map { [$0] } ?? []
        for code in languages.subtracting(kept?.codes ?? []).sorted() {
            guard let url = bundle.url(forResource: code, withExtension: ModelFile.fileExtension) else {
                log.info("no \(code, privacy: .public).\(ModelFile.fileExtension) in \(bundle.bundlePath, privacy: .public)")
                continue
            }
            if let model = model(at: url.path) { models.append(model) }
        }
        guard !models.isEmpty else {
            log.error("no model for \(languages.sorted().joined(separator: ", "), privacy: .public): automatic switching is off")
            return nil
        }
        return models.count == 1 ? models[0] : LanguageModel(combining: models)
    }

    /// A model file or a directory of them, for tests and tools.
    public static func model(at path: String) -> LanguageModel? {
        do {
            let model = try ModelFile.load(path)
            log.info("model \(path, privacy: .public): \(model.languages.map(\.code).joined(separator: ", "), privacy: .public), \(model.byteCount / 1024) KB")
            return model
        } catch {
            log.error("model \(path, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
