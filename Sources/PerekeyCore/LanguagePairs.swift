// SPDX-License-Identifier: GPL-3.0-or-later

/// Which pairs of the installed languages Perekey switches by itself and which
/// only on the user's command (docs/PLAN.md, stage 8). Layouts of one language
/// (ABC and US Extended) count once. A statement for the settings and the
/// onboarding; the rule itself is `Classifier.switchesAutomatically`.
public struct LanguagePairs: Equatable, Sendable {
    public struct Pair: Equatable, Hashable, Sendable {
        public let first: String
        public let second: String
    }

    /// The languages of the layouts, each once, in system order.
    public let languages: [String]
    /// Latin ↔ Cyrillic: automatic switching works, and the manual retype.
    public let automatic: [Pair]
    /// Two languages of one script (ru ↔ uk): only the manual retype.
    public let manualOnly: [Pair]

    public init(languages all: [String]) {
        var seen = Set<String>()
        let languages = all.filter { seen.insert($0).inserted }
        var automatic: [Pair] = []
        var manualOnly: [Pair] = []
        // A language with no known script has no pair: nothing to compare it with.
        let scripted = languages.filter { Classifier.Script(language: $0) != nil }
        for (index, first) in scripted.enumerated() {
            for second in scripted[(index + 1)...] {
                if Classifier.switchesAutomatically(from: first, to: second) {
                    automatic.append(Pair(first: first, second: second))
                } else {
                    manualOnly.append(Pair(first: first, second: second))
                }
            }
        }
        self.languages = languages
        self.automatic = automatic
        self.manualOnly = manualOnly
    }

    public init(layouts: [LayoutMap]) {
        self.init(languages: layouts.compactMap(\.language))
    }

    /// More than two languages: the user has a choice to be told about.
    public var hasChoice: Bool { languages.count > 2 }
}
