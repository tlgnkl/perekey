// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyEvalKit
import Testing

/// A run written one case at a time has the bytes of a run written from all the scores.
@Suite struct StreamingRunTests {
    @Test func theWriterGivesTheBytesOfWrite() throws {
        let whole = RunDirectory.temporary(), streamed = RunDirectory.temporary()
        let scores = try RunDirectory.play(RunDirectory.cases(), to: whole)
        let info = RunFiles.Info(commit: "abc1234", models: ["ru": "62b5126aaaa"], system: "machine",
                                 files: [], split: "all", tier: "ci", testRevealed: false,
                                 lexicon: ["ru": "00", "en": "11"])
        let writer = try RunFiles.Writer(to: streamed, personal: false)
        for score in scores { try writer.add(score) }
        let summary = try writer.finish(info: info)
        #expect(summary == Summary(scores))
        let names = try FileManager.default.contentsOfDirectory(atPath: whole).sorted()
        #expect(names == ["cases.tsv", "counts.tsv", "events.jsonl", "run.json", "slices.json", "summary.json", "words.tsv"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: streamed).sorted() == names)
        for name in names {
            #expect(try String(contentsOfFile: whole + "/" + name, encoding: .utf8)
                == String(contentsOfFile: streamed + "/" + name, encoding: .utf8), "\(name)")
        }
    }

    @Test func aFileIsReadInPiecesToTheSameCases() throws {
        let path = Repo.path("eval/cases/incidents.jsonl")
        var streamed: [EvalCase] = []
        try CaseCodec.forEach(file: path) { streamed.append($0) }
        #expect(streamed == (try CaseCodec.read(String(contentsOfFile: path, encoding: .utf8), file: path)))
        #expect(!streamed.isEmpty)
    }
}
