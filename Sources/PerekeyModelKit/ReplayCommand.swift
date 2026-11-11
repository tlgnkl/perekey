// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// `perekey-eval replay check|words|compare` (docs/classifier.md, «Замер на
/// живых сессиях»):
///
///     replay check <files> --model <dir> [--show-words]
///     replay words <files> --model <dir> [--json <file>] [--show-words]
///     replay compare <files> --model <dir> --candidate-model <dir> [--candidate-options <json|file>]
///                    [--json <file>] [--show-words]
///
/// `check` replays every segment exactly and prints the first answer that
/// differs from the recorded one; exit status 1 then. `words` prints the
/// table of labelled words, `compare` where a candidate classifier decides
/// otherwise. Typed text is printed only with `--show-words`, and never
/// written to the `--json` file.
public enum ReplayCommand {
    public static let usage = """
        usage: perekey-eval replay check|words|compare <files> --model <dir> [--json <file>] [--show-words]
               [--candidate-model <dir>] [--candidate-options <json or file>]
        """

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Runs the command; returns the exit status: 0; 1 when `check` found a
    /// difference, a file was broken or a model could not be loaded; 2 for a
    /// wrong command line: no command, no files, no `--model`, a flag without
    /// its value, a `--candidate-options` that is not `Classifier.Options`.
    public static func run(_ arguments: [String], print: (String) -> Void) -> Int32 {
        guard let command = arguments.first, ["check", "words", "compare"].contains(command) else {
            print(usage)
            return 2
        }
        var files: [String] = []
        var flags: [String: String] = [:]
        var rest = arguments.dropFirst().makeIterator()
        while let argument = rest.next() {
            if argument == "--show-words" {
                flags[argument] = "1"
            } else if argument.hasPrefix("--") {
                guard let value = rest.next() else {
                    print("\(argument) needs a value\n\(usage)")
                    return 2
                }
                flags[argument] = value
            } else {
                files.append(argument)
            }
        }
        guard !files.isEmpty, let model = flags["--model"] else {
            print("the files and --model are required\n\(usage)")
            return 2
        }
        let showWords = flags["--show-words"] != nil
        let base = Models(directory: model, options: nil)
        var options: Classifier.Options?
        if let text = flags["--candidate-options"] {
            do {
                options = try candidateOptions(text)
            } catch {
                print("--candidate-options: \(error)\n\(usage)")
                return 2
            }
        }
        do {
            switch command {
            case "check":
                return try check(files, models: base, showWords: showWords, print: print)
            case "words":
                return try words(files, models: base, json: flags["--json"], showWords: showWords, print: print)
            default:
                guard let candidate = flags["--candidate-model"] else {
                    print("compare needs --candidate-model\n\(usage)")
                    return 2
                }
                return try compare(files, base: base, candidate: Models(directory: candidate, options: options),
                                   json: flags["--json"], showWords: showWords, print: print)
            }
        } catch {
            print("\(error)")
            return 1
        }
    }

    /// The models of a directory, loaded once per set of languages.
    final class Models {
        let directory: String
        /// Options in place of the recorded ones: a candidate's.
        let options: Classifier.Options?
        private var loaded: [[String]: LanguageModel] = [:]
        private(set) var failure: String?

        init(directory: String, options: Classifier.Options?) {
            self.directory = directory
            self.options = options
        }

        func classifier(_ spec: ClassifierSpec) -> Classifier? {
            if loaded[spec.languages] == nil {
                do {
                    loaded[spec.languages] = try ModelFile.load(directory, languages: spec.languages)
                } catch {
                    failure = "cannot load the model of \(spec.languages.joined(separator: ", ")) from \(directory): \(error)"
                    return nil
                }
            }
            return loaded[spec.languages].map { Classifier(model: $0, options: options ?? spec.options) }
        }

        func check() throws {
            if let failure { throw Failure(description: failure) }
        }
    }

    /// `Classifier.Options` from JSON text or a file. A key that is not an
    /// option is an error: a misspelt one would otherwise leave the default
    /// in place and the comparison would measure nothing.
    static func candidateOptions(_ text: String) throws -> Classifier.Options {
        let data = FileManager.default.fileExists(atPath: text)
            ? try Data(contentsOf: URL(fileURLWithPath: text)) : Data(text.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "expected a JSON object of Classifier.Options")
        }
        let known = Set(Classifier.Options.codingKeyNames)
        let unknown = object.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw Failure(description: "unknown options: \(unknown.joined(separator: ", ")); "
                + "known: \(Classifier.Options.codingKeyNames.joined(separator: ", "))")
        }
        return try JSONDecoder().decode(Classifier.Options.self, from: data)
    }

    static func read(_ file: String, print: (String) -> Void) throws -> Session {
        do {
            let session = try SessionFile.read(path: file)
            if session.droppedTail { print("\(file): the last line was cut off and is left out") }
            return session
        } catch {
            throw Failure(description: "\(file): \(error)")
        }
    }

    static func check(_ files: [String], models: Models, showWords: Bool, print: (String) -> Void) throws -> Int32 {
        var status: Int32 = 0
        for file in files {
            let session = try read(file, print: print)
            if session.segments.isEmpty { print("\(file): 0 segments") }
            for (number, segment) in session.segments.enumerated() {
                let run = SessionDriver.run(segment, mode: .exact, classifier: models.classifier)
                try models.check()
                let name = "\(file), segment \(number + 1)"
                guard let mismatch = run.mismatch else {
                    print("\(name): \(segment.steps.count) events, no difference")
                    continue
                }
                status = 1
                let line = mismatch.line.map { " (line \($0))" } ?? ""
                print("\(name): \(segment.steps.count) events, the first difference at event \(mismatch.step + 1)\(line)")
                print("  expected \(digestText(mismatch.expected, showWords: showWords))")
                print("  got      \(digestText(mismatch.got, showWords: showWords))")
            }
        }
        return status
    }

    static func words(_ files: [String], models: Models, json: String?, showWords: Bool,
                      print: (String) -> Void) throws -> Int32
    {
        var summary = SessionSummary()
        var listed: [String] = []
        for file in files {
            let session = try read(file, print: print)
            for segment in session.segments {
                let run = SessionDriver.run(segment, mode: .exact, classifier: models.classifier)
                try models.check()
                let words = SessionWords.extract(run)
                summary.add(run, words: words)
                if showWords { listed.append(SessionReport.words(words, layouts: segment.snapshot.machine.layouts)) }
            }
        }
        print(summary.render())
        if summary.mismatches > 0 {
            print("\nwarning: \(summary.mismatches) segments replay otherwise than recorded (replay check): "
                + "their words follow the replay")
        }
        if showWords { print("\n" + listed.filter { !$0.isEmpty }.joined(separator: "\n")) }
        if let json { try SessionFile.encoder().encode(summary).write(to: URL(fileURLWithPath: json)) }
        return 0
    }

    static func compare(_ files: [String], base: Models, candidate: Models, json: String?, showWords: Bool,
                        print: (String) -> Void) throws -> Int32
    {
        var comparison = SessionComparison()
        var listed: [String] = []
        for file in files {
            let session = try read(file, print: print)
            for segment in session.segments {
                // Both sides run in the same mode: the exact run answers with
                // the recorded events of the machine's own, the simulated one
                // makes them anew, and a difference of modes is not the
                // candidate's. The exact run only calibrates (`Calibration`).
                let exact = SessionWords.extract(SessionDriver.run(segment, mode: .exact, classifier: base.classifier))
                try base.check()
                let simulated = SessionDriver.run(segment, mode: .simulated, classifier: base.classifier)
                try base.check()
                let other = SessionDriver.run(segment, mode: .simulated, classifier: candidate.classifier)
                try candidate.check()
                var part = SessionComparison()
                part.add(base: SessionWords.extract(simulated), candidate: other)
                part.calibrate(exact: exact, simulated: simulated)
                comparison.add(part)
                if showWords { listed.append(part.renderWords(layouts: segment.snapshot.machine.layouts)) }
            }
        }
        print(comparison.render())
        if showWords { print("\n" + listed.filter { !$0.isEmpty }.joined(separator: "\n")) }
        if let json { try SessionFile.encoder().encode(comparison).write(to: URL(fileURLWithPath: json)) }
        return 0
    }

    /// A digest as one line of JSON; the text of corrections as "x" unless shown.
    static func digestText(_ digest: OutputDigest, showWords: Bool) -> String {
        var digest = digest
        if !showWords {
            digest.effects = digest.effects.map { effect in
                switch effect {
                case var .corrected(correction):
                    correction.original = String(repeating: "x", count: correction.original.count)
                    correction.replacement = String(repeating: "x", count: correction.replacement.count)
                    return .corrected(correction)
                case let .alwaysFixWithdrawn(word):
                    return .alwaysFixWithdrawn(String(repeating: "x", count: word.count))
                default:
                    return effect
                }
            }
        }
        let data = (try? SessionFile.encoder().encode(digest)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

extension SessionComparison {
    /// Adds the counts and rows of another part.
    public mutating func add(_ other: SessionComparison) {
        words += other.words
        differ += other.differ
        strongFixed += other.strongFixed
        strongBroken += other.strongBroken
        weakDiffer += other.weakDiffer
        unclearDiffer += other.unclearDiffer
        calibration.words += other.calibration.words
        calibration.differ += other.calibration.differ
        rows += other.rows
    }
}
