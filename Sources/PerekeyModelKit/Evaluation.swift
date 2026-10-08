// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Runs the classifier over the held-out corpus and counts false switches
/// and missed ones per category. Every word is typed twice: in its own layout
/// (a switch is a false positive) and in the other layout (no switch is a
/// miss), except categories that are only ever typed in the English layout.
///
/// Typo correction is measured on the same pass (docs/classifier.md,
/// «Опечатки»): every word the classifier keeps in its own layout goes to
/// the `TypoCorrector`. A clean word it changes is a wrong correction; a
/// word of the typos category must come back as the word meant.
public struct Evaluation {
    public struct Case: Hashable, Sendable {
        public var item: CorpusItem
        /// The layout that was active.
        public var typed: LayoutID
        public var expectSwitch: Bool
        public var decision: Classifier.Decision
        /// What the typo corrector made of the word, when that was the error.
        public var correction: String?
    }

    public struct Category: Hashable, Sendable {
        public var name: String
        /// Words typed in their own layout, and how many switched.
        public var keepWords = 0
        public var falseSwitches = 0
        /// Words typed in the other layout, and how many switched back.
        public var switchWords = 0
        public var switches = 0
        /// Words the corrector saw in their own layout, and how many it
        /// changed although they were right (clean categories) or changed
        /// to the wrong word (typos).
        public var checkedWords = 0
        public var wrongCorrections = 0
        /// Typos, and how many came back as the word meant: in their own
        /// layout, and in the other layout after the switch.
        public var typoWords = 0
        public var typosFixed = 0
        public var typosFixedAfterSwitch = 0
        /// Typos that are words themselves ("form" for "from"): the
        /// corrector leaves known words alone, so these set the ceiling.
        public var typosThatAreWords = 0

        public var falseRate: Double { keepWords > 0 ? Double(falseSwitches) / Double(keepWords) : 0 }
        public var recall: Double { switchWords > 0 ? Double(switches) / Double(switchWords) : 1 }
        public var wrongCorrectionRate: Double {
            checkedWords > 0 ? Double(wrongCorrections) / Double(checkedWords) : 0
        }
        public var fixedShare: Double { typoWords > 0 ? Double(typosFixed) / Double(typoWords) : 0 }
    }

    public struct Results: Sendable {
        public var threshold: Double
        public var options = Classifier.Options()
        public var typoOptions: TypoCorrector.Options
        public var categories: [Category]
        public var untypeable = 0
        public var errors: [Case]

        /// Recall over prose and chat: the plan's target applies to text.
        public var textRecall: Double {
            let text = categories.filter { $0.name == "prose" || $0.name == "chat" }
            let words = text.reduce(0) { $0 + $1.switchWords }
            return words > 0 ? Double(text.reduce(0) { $0 + $1.switches }) / Double(words) : 1
        }

        public var total: Category {
            var total = Category(name: "all")
            for category in categories {
                total.keepWords += category.keepWords
                total.falseSwitches += category.falseSwitches
                total.switchWords += category.switchWords
                total.switches += category.switches
                total.checkedWords += category.checkedWords
                total.wrongCorrections += category.wrongCorrections
                total.typoWords += category.typoWords
                total.typosFixed += category.typosFixed
                total.typosFixedAfterSwitch += category.typosFixedAfterSwitch
                total.typosThatAreWords += category.typosThatAreWords
            }
            return total
        }

        /// The plan's targets for typo correction: wrong corrections under
        /// 0.1 % of words, at least 60 % of typos fixed.
        public var typoTargetsMet: Bool {
            let total = total
            return total.wrongCorrectionRate < 0.001 && total.fixedShare >= 0.6
        }
    }

    public let layouts: [String: LayoutMap]
    public var options: Classifier.Options
    public var typoOptions: TypoCorrector.Options
    let model: LanguageModel

    /// - Parameter layouts: one layout per language code, e.g. ["ru": Russian, "en": ABC].
    public init(model: LanguageModel, layouts: [String: LayoutMap], options: Classifier.Options = .init(),
                typoOptions: TypoCorrector.Options = .init())
    {
        self.model = model
        self.layouts = layouts
        self.options = options
        self.typoOptions = typoOptions
    }

    /// - Parameter maxErrors: how many wrong decisions to keep per category as examples.
    public func run(_ items: [CorpusItem], maxErrors: Int = 20) -> Results {
        let classifier = Classifier(model: model, options: options)
        let corrector = TypoCorrector(model: model, options: typoOptions)
        var categories: [String: Category] = [:]
        var results = Results(threshold: options.threshold, typoOptions: typoOptions, categories: [], errors: [])
        results.options = options
        var errorCounts: [String: Int] = [:]
        func record(_ item: CorpusItem, typed: LayoutID, expectSwitch: Bool, decision: Classifier.Decision,
                    correction: String? = nil)
        {
            guard errorCounts[item.category, default: 0] < maxErrors else { return }
            errorCounts[item.category, default: 0] += 1
            results.errors.append(Case(item: item, typed: typed, expectSwitch: expectSwitch, decision: decision,
                                       correction: correction))
        }
        for item in items {
            guard let own = layouts[item.language],
                  let other = layouts.first(where: { $0.key != item.language })?.value
            else { continue }
            var strokes: [KeyStroke] = []
            var typeable = true
            for character in item.text {
                guard let stroke = own.stroke(for: character) else {
                    typeable = false
                    break
                }
                strokes.append(stroke)
            }
            guard typeable else {
                results.untypeable += 1
                continue
            }
            var category = categories[item.category, default: Category(name: item.category)]
            let context = Classifier.Context(recent: RecentLanguages(item.recent),
                                             prior: item.app.map { LanguagePrior(counts: $0) } ?? LanguagePrior())
            // Without a word before it the word starts the text: a capital is allowed.
            let sentenceStart = item.previous == nil

            let kept = classifier.classify(strokes, typed: own, other: other, context: context)
            category.keepWords += 1
            var keptInOwnLayout = true
            if case .switch = kept.verdict {
                category.falseSwitches += 1
                keptInOwnLayout = false
                record(item, typed: own.id, expectSwitch: false, decision: kept)
            }

            if item.category == "typos" {
                // The word the user meant must come back, in its own layout
                // and after the switch from the other one.
                category.typoWords += 1
                category.checkedWords += 1
                if let language = model.language(item.language),
                   language.rank(of: ModelFormat.Fingerprint.of(item.text.unicodeScalars, folded: true)) != nil
                {
                    category.typosThatAreWords += 1
                }
                let fix = keptInOwnLayout
                    ? corrector.correct(strokes, in: own, sentenceStart: sentenceStart)?.text : nil
                if fix == item.expected {
                    category.typosFixed += 1
                } else {
                    if fix != nil { category.wrongCorrections += 1 }
                    record(item, typed: own.id, expectSwitch: false, decision: kept, correction: fix ?? "-")
                }
                let wrong = classifier.classify(strokes, typed: other, other: own, context: context)
                category.switchWords += 1
                if wrong.verdict == .switch(to: own.id) {
                    category.switches += 1
                    if corrector.correct(strokes, in: own, sentenceStart: sentenceStart)?.text == item.expected {
                        category.typosFixedAfterSwitch += 1
                    }
                }
                categories[item.category] = category
                continue
            }

            if keptInOwnLayout {
                // A right word the corrector changes is a wrong correction.
                category.checkedWords += 1
                if let fix = corrector.correct(strokes, in: own, sentenceStart: sentenceStart) {
                    category.wrongCorrections += 1
                    record(item, typed: own.id, expectSwitch: false, decision: kept, correction: fix.text)
                }
            }

            if Corpus.switchable.contains(item.category) {
                let wrong = classifier.classify(strokes, typed: other, other: own, context: context)
                category.switchWords += 1
                if wrong.verdict == .switch(to: own.id) {
                    category.switches += 1
                } else {
                    record(item, typed: other.id, expectSwitch: true, decision: wrong)
                }
            } else if !Corpus.englishOnly.contains(item.category) {
                // Captcha in the other layout: still nothing to switch to.
                let wrong = classifier.classify(strokes, typed: other, other: own, context: context)
                category.keepWords += 1
                if case .switch = wrong.verdict {
                    category.falseSwitches += 1
                    record(item, typed: other.id, expectSwitch: false, decision: wrong)
                }
            }
            categories[item.category] = category
        }
        results.categories = Corpus.categories.compactMap { categories[$0] }
        return results
    }

    /// Runs the corpus at every threshold: the ROC points.
    public func sweep(_ items: [CorpusItem], thresholds: [Double]) -> [Results] {
        thresholds.map { threshold in
            var evaluation = self
            evaluation.options.threshold = threshold
            return evaluation.run(items, maxErrors: 0)
        }
    }

    /// Runs the corpus at every pair of context options: the points to pick
    /// `contextBonus` and `contextDecay` from.
    public func contextSweep(_ items: [CorpusItem], bonuses: [Double], decays: [Double]) -> [Results] {
        var points: [Results] = []
        for bonus in bonuses {
            for decay in decays {
                var evaluation = self
                evaluation.options.contextBonus = bonus
                evaluation.options.contextDecay = decay
                points.append(evaluation.run(items, maxErrors: 0))
            }
        }
        return points
    }

    /// Runs the corpus at every pair of prior options: `priorScale` and `priorLimit`.
    public func priorSweep(_ items: [CorpusItem], scales: [Double], limits: [Double]) -> [Results] {
        var points: [Results] = []
        for scale in scales {
            for limit in limits {
                var evaluation = self
                evaluation.options.priorScale = scale
                evaluation.options.priorLimit = limit
                points.append(evaluation.run(items, maxErrors: 0))
            }
        }
        return points
    }

    /// Runs the corpus at every pair of typo options: the points to pick
    /// `minScore` and `margin` from.
    public func typoSweep(_ items: [CorpusItem], scores: [Int], margins: [Int]) -> [Results] {
        var points: [Results] = []
        for score in scores {
            for margin in margins {
                var evaluation = self
                evaluation.typoOptions.minScore = score
                evaluation.typoOptions.margin = margin
                points.append(evaluation.run(items, maxErrors: 0))
            }
        }
        return points
    }

    public static func report(_ results: Results) -> String {
        var text = String(format: "threshold %.1f bits, context %.1f bits decaying by %.2f, "
                          + "prior ×%.2f up to %.1f bits; %d words skipped (not typeable)\n", results.threshold,
                          results.options.contextBonus, results.options.contextDecay,
                          results.options.priorScale, results.options.priorLimit, results.untypeable)
        text += "category    words   false switches     rate   wrong layout  switched   recall\n"
        for category in results.categories + [results.total] {
            text += String(format: "%-9@ %7d %16d %7.3f%% %14d %9d %7.2f%%\n", category.name as NSString,
                           category.keepWords, category.falseSwitches, category.falseRate * 100,
                           category.switchWords, category.switches, category.recall * 100)
        }
        text += String(format: "\ntypo correction: minScore %d, margin %d\n", results.typoOptions.minScore,
                       results.typoOptions.margin)
        text += "category  checked   wrong corrections     rate    typos    fixed    share  after switch  are words\n"
        for category in results.categories + [results.total] {
            text += String(format: "%-9@ %7d %19d %7.3f%% %8d %8d %7.2f%% %13d %10d\n", category.name as NSString,
                           category.checkedWords, category.wrongCorrections, category.wrongCorrectionRate * 100,
                           category.typoWords, category.typosFixed, category.fixedShare * 100,
                           category.typosFixedAfterSwitch, category.typosThatAreWords)
        }
        return text
    }
}
