// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
@testable import PerekeyEvalKit
import Testing

/// The table of outcomes (docs/eval.md, «Исходы»), a line per test, and the alignment.
@Suite struct ScorerTests {
    let scorer = Scorer(library: Repo.library)

    /// A case of one measured token "привет" typed on Russian.
    func item(_ want: String = "привет", err: TokenError = .none, accept: [String]? = nil,
              fold: [EvalCase.Fold]? = nil, script: [Step]? = nil) -> EvalCase
    {
        let tokens = Tokenizer.tokens(want).map { TokenSpec(t: $0, lang: "ru", err: err, accept: accept) }
        return Cases.make(script ?? [.type(want + " ", on: "Russian")], want: want, tokens: tokens, fold: fold)
    }

    func outcomes(_ item: EvalCase, null: String, out: String) -> [Outcome] {
        scorer.score(item, null: result(null), out: result(out)).tokens.map(\.outcome)
    }

    @Test func aRunOfWrongTokensStaysOnItsPlaces() {
        // Chat line typed on the wrong layout: nine tokens each side, five wrong. A split and
        // a merge at 2.5 each (5.0) used to beat three 1:1 pairs (6.0).
        let line = item("он не подаёт признаков жизни", err: .layout)
        let wrong = "jy yt gjlf\\n ghbpyfrjd ;bpyb"
        let score = scorer.score(line, null: result(wrong), out: result("jy не подаёт признаков жизни"))
        #expect(score.tokens.map(\.null) == ["jy", "yt", "gjlf\\n", "ghbpyfrjd", ";bpyb"])
        #expect(score.tokens.map(\.outcome) == [.miss, .fixed, .fixed, .fixed, .fixed])
    }

    @Test func aWrongMergeStillLinesUpAsOneGroup() {
        let two = item("во первых")
        #expect(outcomes(two, null: "во первых", out: "вопервых") == [.harm, .harm])
    }

    @Test func rightWithoutRightWithIsOK() {
        #expect(outcomes(item(), null: "привет ", out: "привет ") == [.ok])
    }

    @Test func rightWithoutWrongWithIsHarm() {
        let score = scorer.score(item(), null: result("привет"), out: result("ghbdtn"))
        #expect(score.tokens.map(\.outcome) == [.harm])
        #expect(score.tokens[0].form == "layout")
        #expect(score.harmEvents == 1)
    }

    @Test func wrongWithoutRightWithIsFixed() {
        #expect(outcomes(item(err: .layout), null: "ghbdtn", out: "привет") == [.fixed])
    }

    @Test func wrongBothTheSameIsMiss() {
        #expect(outcomes(item(err: .layout), null: "ghbdtn", out: "ghbdtn") == [.miss])
    }

    @Test func wrongBothChangedIsBotched() {
        let score = scorer.score(item(err: .layout), null: result("ghbdtn"), out: result("прибет"))
        #expect(score.tokens.map(\.outcome) == [.botched])
        #expect(score.tokens[0].form == "edit")
    }

    /// The glue rule only lines tokens up: a merged group is right only when
    /// its text is equal by the folds or accepted (7.2, clarified 10.11.2026).
    @Test func aMergeOfTwoTokensGluedWithAHyphen() {
        let two = item("во первых")
        #expect(outcomes(two, null: "во первых", out: "во-первых") == [.harm, .harm])
        let accepted = item("во первых", accept: ["во-первых"])
        #expect(outcomes(accepted, null: "во первых", out: "во-первых") == [.ok, .ok])
        let ops = Aligner().align(want: ["во", "первых", "да"], out: ["во-первых", "да"],
                                  judge: Scorer.judge(want: ["во", "первых", "да"], fold: [], accept: { _ in [] }))
        #expect(ops == [.merge(w: 0, o: 0), .pair(w: 2, o: 1)])
    }

    @Test func aCutGluedWithAHyphenIsNotTheMeantToken() {
        let hyphened = item("по-новому")
        let score = scorer.score(hyphened, null: result("по новому"), out: result("по новому"))
        #expect(score.tokens.map(\.outcome) == [.miss])
        #expect(score.tokens[0].null == "по новому")
        #expect(outcomes(hyphened, null: "по новому", out: "по-новому") == [.fixed])
    }

    /// An extra token after a merge belongs to the whole group: both tokens
    /// are wrong and both carry it in their output.
    @Test func anExtraTokenAfterAMergeMakesTheWholeGroupWrong() {
        let two = item("во первых")
        let score = scorer.score(two, null: result("во первых"), out: result("во-первых лишнее"))
        #expect(score.tokens.map(\.outcome) == [.harm, .harm])
        #expect(score.tokens.map(\.out) == ["во-первых лишнее", "во-первых лишнее"])
    }

    @Test func aCutOfOneToken() {
        let ops = Aligner().align(want: ["вообще-то", "да"], out: ["вообще", "то", "да"],
                                  judge: Scorer.judge(want: ["вообще-то", "да"], fold: [], accept: { _ in [] }))
        #expect(ops == [.split(w: 0, o: 0), .pair(w: 1, o: 2)])
    }

    @Test func equalCountsDoNotMeanTokensInPlace() {
        // A merge and a cut that cancel out: the alignment still finds both.
        let want = ["во", "первых", "вообще-то"], out = ["во-первых", "вообще", "то"]
        let ops = Aligner().align(want: want, out: out, judge: Scorer.judge(want: want, fold: [], accept: { _ in [] }))
        #expect(ops == [.merge(w: 0, o: 0), .split(w: 2, o: 1)])
    }

    @Test func aDroppedTokenIsWrongAndAnExtraOneMakesItsLeftNeighbourWrong() {
        let three = item("раз два три")
        #expect(outcomes(three, null: "раз два три", out: "раз три") == [.ok, .harm, .ok])
        #expect(outcomes(three, null: "раз два три", out: "раз два лишнее три") == [.ok, .harm, .ok])
        #expect(outcomes(three, null: "раз два три", out: "лишнее раз два три") == [.harm, .ok, .ok])
    }

    @Test func foldYoMakesYoAndYeEqual() {
        let yo = item("ещё", fold: [.yo])
        #expect(outcomes(yo, null: "еще", out: "ещё") == [.ok])
        let strict = item("ещё")
        #expect(outcomes(strict, null: "еще", out: "ещё") == [.fixed])
    }

    @Test func acceptedFormsAreRight() {
        let accepted = item("ok", accept: ["ок"], script: [.type("ok ", on: "ABC")])
        #expect(outcomes(accepted, null: "ok", out: "ок") == [.ok])
    }

    @Test func aBrokenWarmupTokenIsSpill() {
        let warm = Cases.make([.type("привет ", on: "Russian")], want: "I will привет",
                              warmup: [.type("I will ", on: "ABC")])
        let score = scorer.score(warm, null: result("I will ghbdtn"), out: result("I шдд привет"))
        #expect(score.tokens.map(\.outcome) == [.ok, .spill, .fixed])
        #expect(!score.exact)
        #expect(score.outcomeString == "oSF")
        #expect(score.words == 1)
    }

    @Test func lagCountsTokensFromTheFirstLayoutMistakeToTheFirstRightOne() {
        let tokens = ["привет", "мир", "и", "всё"].map { TokenSpec(t: $0, lang: "ru", err: .layout) }
        let slip = Cases.make([.type("привет мир и всё ", on: "Russian")], want: "привет мир и всё", tokens: tokens,
                              scenario: "slip.cold")
        let late = scorer.score(slip, null: result("ghbdtn vbh b dc`"), out: result("ghbdtn vbh и всё"))
        #expect(late.lag == 2)
        let never = scorer.score(slip, null: result("ghbdtn vbh b dc`"), out: result("ghbdtn vbh b dc`"))
        #expect(never.lag == 4)
        let clean = Cases.make([.type("привет ", on: "Russian")], want: "привет", scenario: "clean.cold")
        #expect(scorer.score(clean, null: result("привет"), out: result("привет")).lag == nil)
    }

    @Test func harmEventsAreRunsOfHarmedTokens() {
        let five = item("раз два три четыре пять")
        let score = scorer.score(five, null: result("раз два три четыре пять"), out: result("hfp ldf nhb четыре gznm"))
        #expect(score.tokens.map(\.outcome) == [.harm, .harm, .harm, .ok, .harm])
        #expect(score.harmEvents == 2)
        var metrics = Metrics()
        metrics.add(score)
        metrics.computeRates()
        #expect(metrics.harm == 4)
        #expect(metrics.harmEvents == 2)
        #expect(metrics.rates.harm == 800)
    }

    /// The scorer reads the text alone (rule 2.7): the checks of a case are
    /// a label the runner puts on it and change neither `exact` nor outcomes.
    @Test func aCaseScoredAsAWholeComparesTheTextOnly() {
        let whole = Cases.make([.type("привет ", on: "Russian")], want: "привет", scoring: .case,
                               checks: [.layout("Russian"), .corrections(1)])
        var out = result("привет ")
        #expect(scorer.score(whole, null: result("ghbdtn "), out: out).exact)
        #expect(scorer.score(whole, null: result("ghbdtn "), out: out).failedChecks == [])
        #expect(!scorer.score(whole, null: result(""), out: result("при вет")).exact)
        #expect(Runner.failedChecks(whole, out, library: Repo.library) == [.layout("Russian"), .corrections(1)])
        out.layout = Repo.russian.id
        out.corrections = 1
        #expect(Runner.failedChecks(whole, out, library: Repo.library) == [])
    }

    @Test func theOutcomeDoesNotDependOnTheTrace() {
        let one = item(err: .layout)
        var traced = result("привет")
        traced.trace = [TraceEntry(event: 3, kind: .switched, correction: "layout", reason: "compared", score: 30)]
        let plain = scorer.score(one, null: result("ghbdtn"), out: result("привет"))
        let withTrace = scorer.score(one, null: result("ghbdtn"), out: traced)
        #expect(plain.tokens.map(\.outcome) == withTrace.tokens.map(\.outcome))
    }

    @Test func featuresOfATokenInContext() throws {
        let warm = Cases.make([.type("Привет, ", on: "Russian")], want: "I will Привет,",
                              warmup: [.type("I will ", on: "ABC")])
        let score = scorer.score(warm, null: result("I will Ghbdtn?"), out: result("I will Привет,"))
        let features = try #require(score.tokens[2].features)
        #expect(features.ctx == "against")
        #expect(features.cap == "Title")
        #expect(features.punct == "trail")
        #expect(features.pos == "last")
        #expect(features.len == "5-7")
        #expect(features.end == "punct")
        #expect(features.lang == "ru")
    }

    @Test func capitalsAndMarks() {
        #expect(Scorer.capitals("привет") == "lower")
        #expect(Scorer.capitals("Привет") == "Title")
        #expect(Scorer.capitals("МВД") == "UPPER")
        #expect(Scorer.capitals("iPhone") == "inner")
        #expect(Scorer.capitals("McDonald") == "mixed")
        #expect(Scorer.punctuation("«да»") == "both")
        #expect(Scorer.punctuation("во-первых") == "inside")
        #expect(Scorer.punctuation("(да") == "lead")
    }
}
