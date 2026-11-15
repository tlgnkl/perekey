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
        /// Words of the test part may be shown (`--reveal-test`, rule 2.8).
        public var revealTest = false
        /// The lexicon, the lists of `data/` and the decisions about the source's
        /// noise; without it the scorer gives no `disputed`, `silent`, `known`, `zipf`,
        /// `collision` or `seen`.
        public var knowledge: Knowledge?
        /// The machine keeps the trace of the words it keeps and does not judge
        /// (`CaseSetup.tracesJudgements`). It labels and slices and changes no outcome.
        public var tracesJudgements = true

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
    private var models: [String: LanguageModel] = [:]
    /// SHA-256 of every model file loaded, by language.
    public private(set) var modelHashes: [String: String] = [:]

    public init(config: Config, library: LayoutLibrary, typist: Typist = Typist()) {
        self.config = config
        self.library = library
        self.typist = typist
        scorer = Scorer(library: library, knowledge: config.knowledge)
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
        do {
            return try playChecked(original)
        } catch where original.isPersonal {
            // The message of a failure may quote the person's text.
            throw EvalError.input("\(original.shownID(nil)): cannot be played (\(type(of: error))); the details of a personal case are withheld")
        }
    }

    private mutating func playChecked(_ original: EvalCase) throws -> Played {
        let item = prepared(original)
        let events = try typist.events(for: item, layouts: library)
        let classifier = config.system == .machine ? try classifier(for: item) : nil
        var setup = try CaseSetup(item: item, library: library, classifier: classifier)
        setup.tracesJudgements = config.tracesJudgements
        let system = config.system
        return try scored(item, events: events, setup: setup) { try system.play(setup, events: events) }
    }

    /// Plays a case in a real app (`AppSystem`) and scores it as any other: `app` gets the events of the
    /// typist and returns the run. The preset of the case is the app's own, so `--settings` does not apply.
    public mutating func playApp(_ item: EvalCase, app: (EvalCase, [TypedEvent]) throws -> RunResult) throws -> Played {
        let events = try typist.events(for: item, layouts: library)
        let setup = try CaseSetup(item: item, library: library, classifier: nil)
        return try scored(item, events: events, setup: setup) { try app(item, events) }
    }

    private mutating func scored(_ item: EvalCase, events: [TypedEvent], setup: CaseSetup,
                                 run: () throws -> RunResult) throws -> Played {
        let model = try languageModel(for: item)
        let null = try SystemName.null.play(setup, events: events)
        let out = try run()
        var score = scorer.score(item, null: null, out: out, events: events, model: model)
        score.failedChecks = Self.failedChecks(item, out, library: library)
        score.hidden = item.split == .test && !config.revealTest
        score.personal = item.isPersonal
        return Played(item: item, events: events, null: null, out: out, score: score)
    }

    /// The case's `checks` over what the system reports of itself: the
    /// layout at the end, corrections shown and undone. A label of the case,
    /// apart from the scorer, which reads the text alone (rule 2.7).
    public static func failedChecks(_ item: EvalCase, _ out: RunResult, library: LayoutLibrary) -> [Check] {
        (item.checks ?? []).filter { check in
            switch check {
            case let .layout(name): library[name]?.id != out.layout
            case let .corrections(count): out.corrections != count
            case let .undone(count): out.undone != count
            }
        }
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
        models[key] = loaded
        try recordHashes(model, languages: languages)
        return classifier
    }

    /// The model the case's languages play with, for the feature `known`; nil
    /// when the run has no model or no lexicon to go with it.
    mutating func languageModel(for item: EvalCase) throws -> LanguageModel? {
        guard config.knowledge != nil, config.model != nil else { return nil }
        _ = try classifier(for: item)
        let languages = Array(Set(try library.maps(of: item).compactMap(\.language))).sorted()
        return models[languages.joined(separator: ",")]
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

    /// Every case of the files, in order, with the file it came from. A
    /// personal case lives in a file of the private `store` and nowhere
    /// else, and a file of the store holds nothing but personal cases: a
    /// case read from the store has its words hashed in every file and
    /// output, and one outside it must not stand for a person's words.
    public static func read(_ files: [String], store: PrivateStore? = nil) throws -> [(file: String, item: EvalCase)] {
        var result: [(String, EvalCase)] = []
        try forEach(files, store: store) { result.append(($0, $1)) }
        return result
    }

    /// The same cases one at a time, each file read in pieces: a corpus of gigabytes need not fit in memory.
    public static func forEach(_ files: [String], store: PrivateStore? = nil,
                               _ body: (_ file: String, _ item: EvalCase) throws -> Void) throws {
        for file in files {
            let inStore = store?.contains(file) ?? false
            do {
                try CaseCodec.forEach(file: file) { item in
                    if item.isPersonal, !inStore {
                        throw EvalError.input("\(item.shownID(nil)): a personal case is read only from a file inside \(PrivateStore.variable)"
                            + (store == nil ? ", which is not set" : ""))
                    }
                    if !item.isPersonal, inStore {
                        throw EvalError.input("\(file): a file inside \(PrivateStore.variable) holds only personal. suites")
                    }
                    try body(file, item)
                }
            } catch let error as CaseCodec.ReadError {
                // The message of a decoding error may quote the value.
                throw EvalError.input(inStore ? "\(file):\(error.line): not a case; the details of a personal file are withheld"
                    : error.description)
            }
        }
    }
}
