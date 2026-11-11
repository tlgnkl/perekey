// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk
@testable import PerekeyEvalKit
import Testing

/// The trace of the judgement of the words the machine kept or did not judge
/// (plan E7, step 1): reasons and margins for the misses.
@Suite struct JudgementTraceTests {
    static func play(_ item: EvalCase, traces: Bool) throws -> (out: RunResult, null: RunResult) {
        let events = try Typist().events(for: item, layouts: Repo.library)
        var setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        setup.tracesJudgements = traces
        let null = try SystemName.null.play(setup, events: events)
        return (try SystemName.machine.play(setup, events: events), null)
    }

    /// A word of the Russian layout the fixture model does not know: typed in
    /// the Latin one, the machine keeps it.
    static let missed = Cases.make([.type("мердж ", on: "Russian")], want: "мердж", scenario: "slip.cold")

    @Test func aKeptWordCarriesTheReasonAndTheMargin() throws {
        let played = try Self.play(Cases.make([.type("hello ", on: "ABC")], want: "hello"), traces: true)
        let kept = played.out.trace.filter { $0.kind == .kept }
        #expect(kept.count == 1)
        #expect(kept[0].reason != nil, "a kept word names why the classifier kept it")
    }

    @Test func aWordNotJudgedNamesWhy() throws {
        let item = Cases.make([.type("hello ", on: "ABC")], want: "hello", env: Env(mode: .manualOnly))
        let played = try Self.play(item, traces: true)
        let skipped = played.out.trace.filter { $0.kind == .notJudged }
        #expect(skipped.map(\.reason) == ["skip:appMode"])
    }

    @Test func theTraceIsOffWhenAskedAndTheDeskHoldsNone() throws {
        let played = try Self.play(Cases.make([.type("hello ", on: "ABC")], want: "hello"), traces: false)
        #expect(!played.out.trace.contains { $0.kind == .kept || $0.kind == .notJudged })
    }

    /// Rule 2.7: the trace labels and slices, it changes no outcome.
    @Test(arguments: [
        "flow.basics.jsonl", "incidents.jsonl",
    ])
    func theTraceChangesNoText(file: String) throws {
        for item in try CaseCodec.read(file: Repo.path("eval/cases/" + file)) {
            let with = try Self.play(item, traces: true)
            let without = try Self.play(item, traces: false)
            #expect(with.out.text == without.out.text, "the trace changed the text of \(item.id)")
            #expect(with.out.layout == without.out.layout)
            #expect(with.out.corrections == without.out.corrections)
            #expect(with.out.undone == without.out.undone)
        }
    }

    @Test func theFilesOfARunAreTheSameWithTheTraceOffExceptTheSlices() throws {
        let items = try RunDirectory.cases()
        func scores(traces: Bool) throws -> [CaseScore] {
            var config = Runner.Config()
            config.classifier = Repo.classifier
            config.tracesJudgements = traces
            var runner = Runner(config: config, library: Repo.library)
            return try items.map { try runner.play($0).score }
        }
        let on = try scores(traces: true), off = try scores(traces: false)
        #expect(RunFiles.casesTSV(on) == RunFiles.casesTSV(off))
        #expect(try RunFiles.summaryJSON(on) == RunFiles.summaryJSON(off))
        #expect(RunFiles.countsTSV(on) == RunFiles.countsTSV(off))
        #expect(RunFiles.wordsTSV(on) == RunFiles.wordsTSV(off))
        let withTrace = SliceTable(on), without = SliceTable(off)
        func words(_ table: SliceTable) -> Int {
            (table.features["reason"] ?? [:]).values.reduce(0) { $0 + $1.words }
        }
        #expect(words(withTrace) > words(without), "the trace adds the kept words")
        for feature in ["lang", "len", "pos", "ctx", "cap", "err", "end"] {
            #expect(withTrace.features[feature] == without.features[feature], "\(feature)")
        }
    }

    /// The trace is on by default: a rerun of an old set gets the slices `reason` and `margin` for the kept
    /// and not judged words (docs/eval.md, «История определений»), and nothing else in `slices.json` moves.
    @Test func slicesOfAnOldSetDifferOnlyInTheReasonAndMargin() throws {
        let items = try RunDirectory.cases()
        func slices(traces: Bool) throws -> [String: Any] {
            var config = Runner.Config()
            config.classifier = Repo.classifier
            config.tracesJudgements = traces
            var runner = Runner(config: config, library: Repo.library)
            let scores = try items.map { try runner.play($0).score }
            let object = try JSONSerialization.jsonObject(with: Data(try RunFiles.slicesJSON(scores).utf8))
            return try #require(object as? [String: Any])
        }
        var base = try slices(traces: false), now = try slices(traces: true)
        var baseFeatures = try #require(base["features"] as? [String: Any])
        var nowFeatures = try #require(now["features"] as? [String: Any])
        let added: Set = ["reason", "margin"]
        #expect(Set(nowFeatures.keys).subtracting(baseFeatures.keys).isSubset(of: added), "only reason and margin are new features")
        #expect(Set(baseFeatures.keys).isSubset(of: Set(nowFeatures.keys)), "no feature is gone")
        for key in added { baseFeatures[key] = nil; nowFeatures[key] = nil }
        base["features"] = baseFeatures
        now["features"] = nowFeatures
        #expect(NSDictionary(dictionary: base).isEqual(to: now), "every other key and number is the base's")
    }

    @Test func aDeskWithoutTheTraceListsNoJudgement() throws {
        let item = Cases.make([.type("hello ", on: "ABC"), .type("привет ", on: "Russian")], want: "hello", scoring: .case)
        let setup = try CaseSetup(item: item, library: Repo.library, classifier: Repo.classifier)
        for traces in [false, true] {
            var desk = EvalDesk(EvalDesk.Setup(settings: setup.settings, layouts: setup.layouts, start: setup.start.id,
                                               classifier: setup.classifier, focus: Focus(bundleID: "com.apple.TextEdit"),
                                               tracesJudgements: traces))
            for typed in try Typist().events(for: item, layouts: Repo.library) { desk.send(typed.event, at: typed.time) }
            desk.finish()
            #expect(desk.machine.tracesJudgements == traces)
            #expect(desk.judgements.isEmpty != traces)
            #expect((desk.machine.lastJudgement == nil) != traces)
        }
    }

    @Test func aMissIsSlicedByItsReason() throws {
        let scores = try RunDirectory.play([Self.missed], to: RunDirectory.temporary(), knowledge: false)
        let token = try #require(scores[0].measured.first)
        #expect(token.outcome == .miss)
        let reason = try #require(token.features?.reason, "the miss has the reason the classifier kept the word")
        let slices = SliceTable(scores)
        let row = try #require(slices.features["reason"]?[reason])
        #expect(row.miss == 1)
        let data = try ReportBuilder.build(RunData.load(runDirectory(scores)))
        #expect(data.reasons[reason]?.miss == 1)
        #expect(ReportRender.text(data).contains("причина: \(reason)"))
    }

    func runDirectory(_ scores: [CaseScore]) throws -> String {
        let directory = RunDirectory.temporary()
        try RunDirectory.play([Self.missed], to: directory, knowledge: false)
        return directory
    }

    @Test func theMarginOfASwitchIsTheScoreAboveTheThresholdAsBefore() {
        #expect(Scorer.marginBucket(score: 12, margin: 10) == "<3")
        #expect(Scorer.marginBucket(score: 14, margin: 10) == "3-10")
        #expect(Scorer.marginBucket(score: 25, margin: 10) == "10+")
        #expect(Scorer.marginBucket(score: 4, margin: 10) == "<3", "an early switch under the threshold, as before")
        #expect(Scorer.marginBucket(score: -.infinity, margin: 10) == nil, "the other reading is no word")
    }

    @Test func theMarginOfAKeptWordIsTheScoreUnderTheThreshold() {
        #expect(Scorer.marginBucket(score: 8, margin: 10, kept: true) == "<3", "kept 2 bits short")
        #expect(Scorer.marginBucket(score: 4, margin: 10, kept: true) == "3-10")
        #expect(Scorer.marginBucket(score: -5, margin: 10, kept: true) == "10+", "kept 15 bits short")
        #expect(Scorer.marginBucket(score: 12, margin: 10, kept: true) == "<3", "kept although over the threshold")
        #expect(Scorer.marginBucket(score: -.infinity, margin: 10, kept: true) == nil)
    }
}
