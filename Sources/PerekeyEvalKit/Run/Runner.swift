// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import PerekeyCore

/// Plays cases on a system and on Null and scores them.
public struct Runner {
    public struct Config: Sendable {
        public var system: SystemName = .machine
        /// A model file or a directory of `<language>.pklm`.
        public var model: String?
        /// The classifier when there is no `model` (tests); without both,
        /// the machine plays without one.
        public var classifier: Classifier?
        public var options = Classifier.Options()
        /// The `--options` JSON as given, for run.json.
        public var optionsJSON: String?
        /// A preset over every case's own (`--settings`).
        public var settings: String?

        public init() {}
    }

    /// A played and scored case.
    public struct Played: Sendable {
        public var item: EvalCase
        public var events: [TypedEvent]
        public var null: RunResult
        public var out: RunResult
        public var score: CaseScore
    }

    public let config: Config
    public let library: LayoutLibrary
    public let typist: Typist
    public let scorer: Scorer
    private var classifiers: [String: Classifier] = [:]
    /// SHA-256 of every model file loaded, by language.
    public private(set) var modelHashes: [String: String] = [:]

    public init(config: Config, library: LayoutLibrary, typist: Typist = Typist()) {
        self.config = config
        self.library = library
        self.typist = typist
        scorer = Scorer(library: library)
    }

    /// The case as this run plays it: with the `--settings` preset.
    public func prepared(_ item: EvalCase) -> EvalCase {
        guard let settings = config.settings else { return item }
        var copy = item
        var env = copy.env ?? Env()
        env.settings = settings
        copy.env = env
        return copy
    }

    public mutating func play(_ original: EvalCase) throws -> Played {
        let item = prepared(original)
        let events = try typist.events(for: item, layouts: library)
        let classifier = config.system == .machine ? try classifier(for: item) : nil
        let setup = try CaseSetup(item: item, library: library, classifier: classifier)
        let null = try SystemName.null.play(setup, events: events)
        let out = try config.system.play(setup, events: events)
        return Played(item: item, events: events, null: null, out: out,
                      score: scorer.score(item, null: null, out: out, events: events))
    }

    /// One classifier per set of languages, made once per run.
    public mutating func classifier(for item: EvalCase) throws -> Classifier? {
        guard let model = config.model else { return config.classifier }
        let languages = Array(Set(try library.maps(of: item).compactMap(\.language))).sorted()
        let key = languages.joined(separator: ",")
        if let classifier = classifiers[key] { return classifier }
        let loaded = try ModelFile.load(model, languages: languages)
        let classifier = Classifier(model: loaded, options: config.options)
        classifiers[key] = classifier
        try recordHashes(model, languages: languages)
        return classifier
    }

    private mutating func recordHashes(_ model: String, languages: [String]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: model, isDirectory: &isDirectory) else { return }
        if !isDirectory.boolValue {
            modelHashes[(model as NSString).lastPathComponent] = try Self.sha256(file: model)
            return
        }
        for language in languages where modelHashes[language] == nil {
            modelHashes[language] = try Self.sha256(file: "\(model)/\(language).\(ModelFile.fileExtension)")
        }
    }

    public static func sha256(file: String) throws -> String {
        sha256(try Data(contentsOf: URL(fileURLWithPath: file), options: .alwaysMapped))
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reading case files.
public enum CaseFiles {
    /// The `.jsonl` files of the arguments: files as they are, directories
    /// by their `.jsonl` files in name order.
    public static func expand(_ paths: [String]) throws -> [String] {
        var files: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw EvalError.input("no such file: \(path)")
            }
            if isDirectory.boolValue {
                let names = try FileManager.default.contentsOfDirectory(atPath: path)
                    .filter { $0.hasSuffix(".jsonl") }.sorted()
                files += names.map { (path as NSString).appendingPathComponent($0) }
            } else {
                files.append(path)
            }
        }
        return files
    }

    /// Every case of the files, in order, with the file it came from.
    public static func read(_ files: [String]) throws -> [(file: String, item: EvalCase)] {
        var result: [(String, EvalCase)] = []
        for file in files {
            do {
                result += try CaseCodec.read(file: file).map { (file, $0) }
            } catch let error as CaseCodec.ReadError {
                throw EvalError.input(error.description)
            }
        }
        return result
    }
}
