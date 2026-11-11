// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
import PerekeyModelKit
@testable import PerekeyEvalKit
import Testing

/// A folder outside the repository and the preview server, for the tests of
/// personal sets, removed with `remove()`.
struct TestStore {
    let store: PrivateStore
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "private-\(UUID().uuidString)"
        // The temporary folder of a test run may be inside a folder the
        // default list forbids (a scratchpad): the check of the list is tested on its own.
        store = try PrivateStore(path: path, forbiddenPrefixes: [], creating: true)
    }

    var environment: [String: String] { [PrivateStore.variable: path] }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// Recordings the code makes: a case played on the machine of the stand with
/// its calls written down, as the app writes them (`SessionTape` of the
/// core's tests does the same with the test desk). Never a real recording.
enum Recording {
    static func session(playing item: EvalCase) throws -> Session {
        try SessionFile.read(SessionFile.data(lines(playing: item)))
    }

    static func lines(playing item: EvalCase) throws -> [SessionLine] {
        let setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        var machine = try MachineSystem(setup: setup)
        let snapshot = SessionSnapshot(machine.desk.machine)
        machine.recording = true
        for typed in try Typist().events(for: item, layouts: Repo.library) { try machine.send(typed.event, at: typed.time) }
        _ = try machine.finish()
        var lines: [SessionLine] = [.header(SessionHeader(perekey: "0.2.0", build: "test", time: 1_762_780_000)),
                                    .snapshot(snapshot)]
        for record in machine.desk.records {
            lines.append(.step(SessionStep(event: RecordedEvent(record.input), output: OutputDigest(record.output))))
        }
        return lines
    }

    static func classifier(_ spec: ClassifierSpec) -> Classifier? {
        Classifier(model: ModelFixture.model, options: spec.options)
    }

    /// A hand-made person: the words are made up and the model of the tests knows them.
    static let script: [Step] = [
        .type("hello world ", on: "ABC"),
        // Perekey switches it; the person presses «Undo» in the hint: a false switch.
        .type("хорошо ", on: "Russian"), .undo(.button),
        // Kept, and the person retypes it with the shortcut: a miss.
        .type("мердж ", on: "Russian"), .hotkey(.convertLastWord),
        // Switched, and the person types on: a weak label.
        .type("привет ", on: "Russian"),
    ]

    static var item: EvalCase { Cases.make(script, want: "-", scoring: .case) }

    static func built(_ session: Session, name: String = "sessions") throws -> (cases: [EvalCase], report: SessionCases.Report) {
        var options = SessionCases.Options()
        options.name = name
        var seen: Set<String> = []
        return try SessionCases.build(session, library: Repo.library, classifier: classifier, options: options, seen: &seen)
    }
}

@Suite struct PrivateStoreTests {
    @Test func aRelativePathIsRefused() {
        #expect(throws: EvalError.self) { try PrivateStore(path: "private", forbiddenPrefixes: []) }
    }

    @Test(arguments: ["/private/tmp/claude-501/x/personal", "/tmp/claude-501/x/personal"])
    func theScratchpadOfTheAgentIsRefused(path: String) {
        do {
            _ = try PrivateStore(path: path)
            Issue.record("the scratchpad was accepted")
        } catch {
            #expect("\(error)".contains("shown to other people"), "\(error)")
        }
    }

    @Test func aFolderInsideTheRepositoryIsRefused() {
        #expect(throws: EvalError.self) { try PrivateStore(path: Repo.path("eval/personal"), forbiddenPrefixes: []) }
    }

    @Test func aMissingFolderIsMadeForTheOwnerAlone() throws {
        let test = try TestStore()
        defer { test.remove() }
        let attributes = try FileManager.default.attributesOfItem(atPath: test.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }

    @Test func aMissingFolderIsAnErrorWhenNotMadeOnPurpose() {
        let path = NSTemporaryDirectory() + "missing-\(UUID().uuidString)"
        #expect(throws: EvalError.self) { try PrivateStore(path: path, forbiddenPrefixes: []) }
    }

    @Test func theEnvironmentNamesTheStore() throws {
        let test = try TestStore()
        defer { test.remove() }
        let found = try PrivateStore.fromEnvironment(test.environment, forbiddenPrefixes: [])
        #expect(found?.root == test.store.root)
        #expect(try PrivateStore.fromEnvironment([:]) == nil)
        #expect(try PrivateStore.fromEnvironment([PrivateStore.variable: ""]) == nil)
    }

    @Test func containsFollowsSymbolicLinks() throws {
        let test = try TestStore()
        defer { test.remove() }
        #expect(test.store.contains(test.path + "/personal.x.jsonl"))
        #expect(!test.store.contains(test.path + "-other/personal.x.jsonl"))
        #expect(!test.store.contains(Repo.path("eval/cases/flow.basics.jsonl")))
        let link = NSTemporaryDirectory() + "link-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: test.path)
        defer { try? FileManager.default.removeItem(atPath: link) }
        #expect(test.store.contains(link + "/file"), "a path through a link is inside")
    }

    @Test func theSaltIsSecretStableAndHashesTellWordsApart() throws {
        let test = try TestStore()
        defer { test.remove() }
        let first = try test.store.redactor()
        let second = try test.store.redactor()
        #expect(first.hash("привет") == second.hash("привет"))
        #expect(first.hash("привет") != first.hash("мир"))
        #expect(!first.hash("привет").contains("привет"))
        let salt = test.path + "/.salt"
        let attributes = try FileManager.default.attributesOfItem(atPath: salt)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let other = try TestStore()
        defer { other.remove() }
        #expect(try other.store.redactor().hash("привет") != first.hash("привет"), "another store, another salt")
    }

    @Test func aFileOfTheStoreIsForTheOwnerAlone() throws {
        let test = try TestStore()
        defer { test.remove() }
        let path = test.path + "/personal.x.jsonl"
        try test.store.write("{}\n", to: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(throws: EvalError.self) { try test.store.write("{}\n", to: Repo.path("eval/x.jsonl")) }
    }
}

@Suite struct SessionCasesTests {
    @Test func theLabelsOfTheBehaviourMakeCases() throws {
        let made = try Recording.built(Recording.session(playing: Recording.item))
        let report = made.report
        #expect(report.segments == 1)
        #expect(report.mismatched == 0)
        #expect(report.labels["falseSwitch.strong"] == 1)
        #expect(report.labels["miss.strong"] == 1)
        #expect(made.cases.count == 2, "\(report.render())")
        let tags = made.cases.map { Set($0.tags ?? []) }
        #expect(tags.contains { $0.contains("falseSwitch") })
        #expect(tags.contains { $0.contains("miss") })
    }

    @Test func aFalseSwitchIsACleanCaseOfTheWordAsTyped() throws {
        let made = try Recording.built(Recording.session(playing: Recording.item))
        let item = try #require(made.cases.first { $0.tags?.contains("falseSwitch") == true })
        #expect(item.scenario == "clean.warm")
        #expect(item.warmup == [.type("hello world ", on: "ABC")])
        #expect(item.want == "hello world [jhjij")
        #expect(item.tokens?.map(\.t) == ["[jhjij"])
        #expect(item.tokens?.map(\.err) == [.none])
        #expect(item.split == .dev && item.suite == "personal.sessions")
    }

    @Test func aMissIsASlipCaseOfTheKeysInTheLayoutTheyWereRetypedIn() throws {
        let made = try Recording.built(Recording.session(playing: Recording.item))
        let item = try #require(made.cases.first { $0.tags?.contains("miss") == true })
        #expect(item.scenario.hasPrefix("slip."))
        #expect(item.tokens?.map(\.err) == [.layout])
        #expect(item.tokens?.map(\.t) == ["vthl;"].map { Repo.russian.convert($0, from: Repo.abc) }, "retyped into Russian")
        #expect(item.start == "ABC" && item.want.hasSuffix(item.tokens![0].t))
    }

    @Test func aWeakLabelMakesNoCase() throws {
        let item = Cases.make([.type("hello world ", on: "ABC"), .type("привет ", on: "Russian")], want: "-",
                              scoring: .case)
        let made = try Recording.built(Recording.session(playing: item))
        #expect(made.cases.isEmpty)
        #expect(made.report.skipped[.notStrong, default: 0] >= 3)
    }

    @Test func everyCaseIsPlayableAndPassesTheCheck() throws {
        for item in try Recording.built(Recording.session(playing: Recording.item)).cases {
            #expect(CaseCheck.problems(item, layouts: Repo.library).isEmpty, "\(item.id)")
            #expect(Set(item.tags ?? []).isSubset(of: SessionCases.allowedTags))
            _ = try Cases.play(item)
        }
    }

    @Test func buildingTwiceGivesTheSameBytes() throws {
        let session = try Recording.session(playing: Recording.item)
        let first = try CaseCodec.write(Recording.built(session).cases)
        let second = try CaseCodec.write(Recording.built(session).cases)
        #expect(first == second && !first.isEmpty)
    }

    @Test func theSameCaseComesOnceFromManyFiles() throws {
        let session = try Recording.session(playing: Recording.item)
        var seen: Set<String> = []
        var options = SessionCases.Options()
        options.name = "sessions"
        let first = try SessionCases.build(session, library: Repo.library, classifier: Recording.classifier,
                                           options: options, seen: &seen)
        let second = try SessionCases.build(session, library: Repo.library, classifier: Recording.classifier,
                                            options: options, seen: &seen)
        #expect(first.cases.count == 2 && second.cases.isEmpty)
        #expect(second.report.skipped[.duplicate] == 2)
    }

    @Test func wordsAfterTheFirstDifferenceFromTheRecordingMakeNoCase() throws {
        let session = try Recording.session(playing: Recording.item)
        var seen: Set<String> = []
        let made = try SessionCases.build(session, library: Repo.library, classifier: { _ in nil },
                                          options: SessionCases.Options(), seen: &seen)
        #expect(made.report.mismatched == 1)
        #expect(made.cases.isEmpty)
    }

    @Test func theCountsHoldNoWord() throws {
        let made = try Recording.built(Recording.session(playing: Recording.item))
        let text = made.report.render()
        for word in ["hello", "world", "[jhjij", "хорошо", "мердж", "привет"] {
            #expect(!text.contains(word))
        }
    }

    @Test func aStrongLabelOfACorrectionPutBackIsNotACase() throws {
        // A typo correction undone with Backspace and put back with the shortcut: the label is «right» and
        // strong, but a case cannot say what the correction was.
        var settings = Settings()
        settings.typoCorrection = true
        let item = Cases.make([.type("wrold ", on: "ABC"), .key(.backspace, n: nil, mods: nil),
                               .hotkey(.convertLastWord), .type("hello ", on: "ABC")],
                              want: "-", env: Env(settings: "all"), scoring: .case)
        let made = try Recording.built(Recording.session(playing: item))
        #expect(made.cases.allSatisfy { $0.tags?.contains("switchKept") != true })
    }
}


/// Rule 2.9 and the machine's rule: a personal set and its runs leave no word
/// in a file or in the output, only hashes and numbers. Every command runs
/// with its output captured (`EvalContext`), and every file the run made is
/// read back.
@Suite(.serialized) struct PersonalPrivacyTests {
    struct Bench {
        let store: TestStore
        let sessions: String
        let model: String
        let capture = EvalContext.Capture()

        init() throws {
            store = try TestStore()
            sessions = NSTemporaryDirectory() + "sessions-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
            try SessionFile.data(Recording.lines(playing: Recording.item))
                .write(to: URL(fileURLWithPath: sessions + "/2026-11-10-1.pksession"))
            model = NSTemporaryDirectory() + "model-\(UUID().uuidString).pklm"
            try Data(ModelFixture.bytes).write(to: URL(fileURLWithPath: model))
        }

        func remove() {
            store.remove()
            try? FileManager.default.removeItem(atPath: sessions)
            try? FileManager.default.removeItem(atPath: model)
        }

        var cases: String { store.path + "/personal.privacy.jsonl" }

        @discardableResult
        func run(_ arguments: [String], environment: [String: String]? = nil) -> Int32 {
            EvalContext.$capture.withValue(capture) {
                EvalContext.$environment.withValue(environment ?? store.environment) {
                    EvalCommands.run(arguments + ["--layouts", Repo.path("eval/layouts")])
                }
            }
        }

        func build() -> Int32 {
            run(["cases", "personal", sessions, "--model", model, "--name", "privacy"])
        }

        /// The words a run could leak: the text meant, what Null typed and what the machine made of it,
        /// and the id of each case, which is a hash of its content that a guess at a word would give back.
        func secrets() throws -> Set<String> {
            var words: Set<String> = []
            for item in try CaseCodec.read(file: cases) {
                let played = try Cases.play(item)
                for text in [item.want, played.null.text, played.out.text] { words.formUnion(Tokenizer.tokens(text)) }
                words.formUnion(Tokenizer.tokens(TargetText.of(item).full))
                words.insert(String(item.id.split(separator: "/").last ?? ""))
            }
            return words.filter { $0.count >= 4 }
        }

        /// Every file under a folder, with its text.
        static func files(under path: String) -> [(path: String, text: String)] {
            guard let walker = FileManager.default.enumerator(atPath: path) else { return [] }
            return walker.compactMap { $0 as? String }.compactMap { name in
                let full = path + "/" + name
                guard let data = FileManager.default.contents(atPath: full) else { return nil }
                return (full, String(decoding: data, as: UTF8.self))
            }
        }

        /// Where the words are: in what files and in what output.
        func leaks(of secrets: Set<String>, in texts: [(name: String, text: String)]) -> [String] {
            texts.flatMap { entry in secrets.filter { entry.text.contains($0) }.map { "\(entry.name) holds \($0.count) letters of a word" } }
        }
    }

    @Test func aRunNamesAPersonalCaseByASaltedId() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let run = bench.store.path + "/run"
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", run]) == 0)
        let own = try CaseCodec.read(file: bench.cases).map(\.id)
        let named = try String(contentsOfFile: run + "/cases.tsv", encoding: .utf8).split(separator: "\n").dropFirst()
            .map { String($0.split(separator: "\t")[0]) }
        #expect(named.count == own.count)
        #expect(Set(named).isDisjoint(with: own))
        #expect(zip(named, own).allSatisfy { $0.split(separator: "/").dropLast() == $1.split(separator: "/").dropLast() },
                "the suite and the scenario stay")
        let again = bench.store.path + "/again"
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", again]) == 0)
        let second = try String(contentsOfFile: again + "/cases.tsv", encoding: .utf8)
        #expect(second == (try String(contentsOfFile: run + "/cases.tsv", encoding: .utf8)), "the same ids in every run of the store")
        #expect(FileManager.default.fileExists(atPath: bench.store.path + "/.metadata_never_index"))
    }

    @Test func theSetIsBuiltInTheStoreAndPrintsCountsOnly() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0, "\(bench.capture.stderr)")
        let secrets = try bench.secrets()
        #expect(!secrets.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bench.cases))
        #expect(bench.capture.stdout.contains("cases: 2"))
        #expect(bench.leaks(of: secrets, in: [("stdout", bench.capture.stdout), ("stderr", bench.capture.stderr)]).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: bench.cases)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func aRunLeavesNoWordInFilesOrOutput() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let secrets = try bench.secrets()
        let runs = ["machine": bench.store.path + "/run-machine", "null": bench.store.path + "/run-null"]
        #expect(bench.run(["play", "--cases", bench.cases, "--model", bench.model, "--out", runs["machine"]!]) == 0,
                "\(bench.capture.stderr)")
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", runs["null"]!]) == 0)
        for format in ["text", "md", "html", "json"] {
            #expect(bench.run(["report", runs["machine"]!, "--format", format, "--slices", "--words", "50"]) == 0)
            #expect(bench.run(["report", runs["machine"]!, "--format", format, "--out",
                               bench.store.path + "/report.\(format)"]) == 0)
        }
        for format in ["text", "md", "json"] {
            #expect(bench.run(["diff", runs["null"]!, runs["machine"]!, "--format", format, "--list", "50"]) == 0)
        }
        #expect(bench.run(["cases", "check", bench.cases]) == 0)
        #expect(bench.run(["cases", "list", bench.cases]) == 0)
        #expect(bench.run(["case", "--cases", bench.cases, "--id", try CaseCodec.read(file: bench.cases)[0].id,
                           "--model", bench.model]) == 2, "a personal case is never shown")
        #expect(bench.run(["selfcheck", "--cases", bench.cases, "--model", bench.model]) == 0, "\(bench.capture.stdout)")

        var texts = [(name: String, text: String)]()
        for run in runs.values {
            for file in Bench.files(under: run) { texts.append(("run file \((file.path as NSString).lastPathComponent)", file.text)) }
        }
        for format in ["text", "md", "html", "json"] {
            let report = try String(contentsOfFile: bench.store.path + "/report.\(format)", encoding: .utf8)
            texts.append(("report.\(format)", report))
        }
        texts += [("stdout", bench.capture.stdout), ("stderr", bench.capture.stderr)]
        #expect(bench.leaks(of: secrets, in: texts).isEmpty, "\(bench.leaks(of: secrets, in: texts))")
        #expect(texts.map(\.text).joined().contains("h:"), "hashes stand for the words")
    }

    /// The test would pass if it could not see words: the same run of cases that
    /// are not personal does leak them to it.
    @Test func theScanSeesWordsInARunOfCasesThatAreNotPersonal() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let secrets = try bench.secrets()
        let items = try CaseCodec.read(file: bench.cases).map { item -> EvalCase in
            var copy = item
            copy.suite = "other." + item.suite.dropFirst(EvalCase.personalPrefix.count)
            return try copy.identified()
        }
        let directory = RunDirectory.temporary()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try RunDirectory.play(items, to: directory, knowledge: false)
        let texts = Bench.files(under: directory).map { (name: $0.path, text: $0.text) }
        #expect(!bench.leaks(of: secrets, in: texts).isEmpty)
    }

    @Test func aRunFolderAndItsFilesAreForTheOwnerAlone() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let run = bench.store.path + "/run"
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", run]) == 0)
        let folder = try FileManager.default.attributesOfItem(atPath: run)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        for file in try FileManager.default.contentsOfDirectory(atPath: run) {
            let attributes = try FileManager.default.attributesOfItem(atPath: run + "/" + file)
            #expect((attributes[.posixPermissions] as? Int) == 0o600, "\(file)")
        }
        let info = try String(contentsOfFile: run + "/run.json", encoding: .utf8)
        #expect(info.contains("\"personal\" : true"))
    }

    @Test func aPersonalRunIsWrittenOnlyInsideTheStore() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let outside = NSTemporaryDirectory() + "outside-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", outside]) == 2)
        #expect(!FileManager.default.fileExists(atPath: outside))
        let run = bench.store.path + "/run"
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", run]) == 0)
        #expect(bench.run(["report", run, "--out", outside + ".txt"]) == 2, "a report of a personal run is a file of the store")
        #expect(!FileManager.default.fileExists(atPath: outside + ".txt"))
        #expect(bench.run(["diff", run, run, "--out", outside + ".txt"]) == 2)
    }

    @Test func personalCasesNeedTheStoreAndTheStoreHoldsNothingElse() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.build() == 0)
        let run = bench.store.path + "/run"
        #expect(bench.run(["play", "--cases", bench.cases, "--system", "null", "--out", run], environment: [:]) == 2,
                "a personal file without the variable")
        let copy = NSTemporaryDirectory() + "personal.copy-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: copy) }
        try FileManager.default.copyItem(atPath: bench.cases, toPath: copy)
        #expect(bench.run(["play", "--cases", copy, "--system", "null", "--out", run + "2"]) == 2,
                "a personal case outside the store")
        try FileManager.default.copyItem(atPath: Repo.path("eval/cases/flow.basics.jsonl"),
                                         toPath: bench.store.path + "/flow.jsonl")
        #expect(bench.run(["play", "--cases", bench.store.path + "/flow.jsonl", "--system", "null",
                           "--out", run + "3"]) == 2, "a case that is not personal inside the store")
    }

    @Test func aBrokenPersonalFileOrCaseNamesNoValueOfTheirs() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let secret = "секретноеслово"
        let broken = bench.store.path + "/personal.broken.jsonl"
        try """
        {"v":1,"suite":"personal.broken","scenario":"clean.cold","split":"dev","layouts":["ABC"],"start":"ABC","script":[],"want":"\(secret)","tokens":[{"t":"\(secret)","lang":"ru","err":"\(secret)"}],"id":"x"}

        """.write(toFile: broken, atomically: true, encoding: .utf8)
        // A case that decodes but does not pass the check: «Ж» is not typed on ABC.
        var item = EvalCase(suite: "personal.bad", scenario: "clean.cold", split: .dev, layouts: ["ABC"], start: "ABC",
                            script: [.type("\(secret) ", on: "ABC")], want: secret,
                            tokens: [TokenSpec(t: secret, lang: "ru")], tags: ["personal", secret])
        item = try item.identified()
        try CaseCodec.write([item]).write(toFile: bench.store.path + "/personal.bad.jsonl", atomically: true, encoding: .utf8)
        for arguments in [["cases", "check", broken], ["cases", "list", broken], ["play", "--cases", broken, "--system", "null", "--out", bench.store.path + "/r1"],
                          ["cases", "check", bench.store.path + "/personal.bad.jsonl"],
                          ["play", "--cases", bench.store.path + "/personal.bad.jsonl", "--system", "null", "--out", bench.store.path + "/r2"],
                          ["selfcheck", "--cases", bench.store.path + "/personal.bad.jsonl", "--model", bench.model]]
        {
            #expect(bench.run(arguments) != 0, "\(arguments)")
        }
        let texts = [("stdout", bench.capture.stdout), ("stderr", bench.capture.stderr)]
        #expect(bench.leaks(of: [secret], in: texts).isEmpty, "\(bench.capture.stdout)\(bench.capture.stderr)")
        #expect(!bench.capture.stdout.isEmpty || !bench.capture.stderr.isEmpty)
    }

    @Test func aBrokenSessionNamesNoValueOfTheirs() throws {
        let bench = try Bench()
        defer { bench.remove() }
        let secret = "секретноеслово"
        try "{\"header\":{\"format\":\"\(secret)\",\"version\":1}}\n".write(
            toFile: bench.sessions + "/2026-11-11-1.pksession", atomically: true, encoding: .utf8)
        try "not json \(secret)\n".write(toFile: bench.sessions + "/2026-11-12-1.pksession", atomically: true, encoding: .utf8)
        for name in ["2026-11-11-1", "2026-11-12-1"] {
            #expect(bench.run(["cases", "personal", bench.sessions + "/\(name).pksession", "--model", bench.model]) == 2)
        }
        #expect(bench.leaks(of: [secret], in: [("stdout", bench.capture.stdout), ("stderr", bench.capture.stderr)]).isEmpty)
    }

    @Test func theStoreMustNotBeInTheRepositoryOrTheScratchpad() throws {
        let bench = try Bench()
        defer { bench.remove() }
        #expect(bench.run(["cases", "personal", bench.sessions, "--model", bench.model],
                          environment: [PrivateStore.variable: Repo.path("eval/personal")]) == 2)
        #expect(bench.run(["cases", "personal", bench.sessions, "--model", bench.model],
                          environment: [PrivateStore.variable: "/private/tmp/claude-501/x"]) == 2)
        #expect(bench.run(["cases", "personal", bench.sessions, "--model", bench.model], environment: [:]) == 2)
        #expect(!FileManager.default.fileExists(atPath: Repo.path("eval/personal")))
    }
}
