// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Runs the classifier over the held-out corpus and counts false switches
/// and missed ones per category. Every word is typed twice: in its own layout
/// (a switch is a false positive) and in the other layout (no switch is a
/// miss), except categories that are only ever typed in the English layout.
public struct Evaluation {
    public struct Case: Hashable, Sendable {
        public var item: CorpusItem
        /// The layout that was active.
        public var typed: LayoutID
        public var expectSwitch: Bool
        public var decision: Classifier.Decision
    }

    public struct Category: Hashable, Sendable {
        public var name: String
        /// Words typed in their own layout, and how many switched.
        public var keepWords = 0
        public var falseSwitches = 0
        /// Words typed in the other layout, and how many switched back.
        public var switchWords = 0
        public var switches = 0

        public var falseRate: Double { keepWords > 0 ? Double(falseSwitches) / Double(keepWords) : 0 }
        public var recall: Double { switchWords > 0 ? Double(switches) / Double(switchWords) : 1 }
    }

    public struct Results: Sendable {
        public var threshold: Double
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
            }
            return total
        }
    }

    public let layouts: [String: LayoutMap]
    public var options: Classifier.Options
    let model: LanguageModel

    /// - Parameter layouts: one layout per language code, e.g. ["ru": Russian, "en": ABC].
    public init(model: LanguageModel, layouts: [String: LayoutMap], options: Classifier.Options = .init()) {
        self.model = model
        self.layouts = layouts
        self.options = options
    }

    /// - Parameter maxErrors: how many wrong decisions to keep per category as examples.
    public func run(_ items: [CorpusItem], maxErrors: Int = 20) -> Results {
        let classifier = Classifier(model: model, options: options)
        var categories: [String: Category] = [:]
        var results = Results(threshold: options.threshold, categories: [], errors: [])
        var errorCounts: [String: Int] = [:]
        func record(_ item: CorpusItem, typed: LayoutID, expectSwitch: Bool, decision: Classifier.Decision) {
            guard errorCounts[item.category, default: 0] < maxErrors else { return }
            errorCounts[item.category, default: 0] += 1
            results.errors.append(Case(item: item, typed: typed, expectSwitch: expectSwitch, decision: decision))
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
            let context = Classifier.Context(previousLanguage: item.previous)

            let kept = classifier.classify(strokes, typed: own, other: other, context: context)
            category.keepWords += 1
            if case .switch = kept.verdict {
                category.falseSwitches += 1
                record(item, typed: own.id, expectSwitch: false, decision: kept)
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

    public static func report(_ results: Results) -> String {
        var text = String(format: "threshold %.1f bits; %d words skipped (not typeable)\n", results.threshold,
                          results.untypeable)
        text += "category    words   false switches     rate   wrong layout  switched   recall\n"
        for category in results.categories + [results.total] {
            text += String(format: "%-9@ %7d %16d %7.3f%% %14d %9d %7.2f%%\n", category.name as NSString,
                           category.keepWords, category.falseSwitches, category.falseRate * 100,
                           category.switchWords, category.switches, category.recall * 100)
        }
        return text
    }
}
