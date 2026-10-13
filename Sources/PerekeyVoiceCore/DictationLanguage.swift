// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The layout to type in after a dictation: the one of the phrase's main
/// language, so that typing on after "открой pull request в main" goes on in
/// Russian. Not the last word's language, which here is English.
public enum DictationLanguage {
    /// The language with the most letters in `text`. A word counts for the
    /// installed layout that can type it and whose language model finds it
    /// likeliest; words no layout types, or that two layouts type equally
    /// well with no model to choose, count for none. Nil on a tie.
    public static func dominant(in text: String, layouts: [LayoutMap], model: LanguageModel?) -> String? {
        var letters: [String: Int] = [:]
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            guard let language = language(of: word.lowercased(), layouts: layouts, model: model) else { continue }
            letters[language, default: 0] += word.count
        }
        let ranked = letters.sorted { $0.value > $1.value }
        guard let top = ranked.first, ranked.dropFirst().first?.value != top.value else { return nil }
        return top.key
    }

    /// The layout to select after pasting `text`, if the current one is of
    /// another language: the first of the dominant language in `layouts`.
    public static func layout(after text: String, layouts: [LayoutMap], current: LayoutID?,
                              model: LanguageModel?) -> LayoutID?
    {
        guard layouts.count > 1, let language = dominant(in: text, layouts: layouts, model: model) else { return nil }
        if let current, layouts.first(where: { $0.id == current })?.language == language { return nil }
        return layouts.first { $0.language == language }?.id
    }

    static func language(of word: String, layouts: [LayoutMap], model: LanguageModel?) -> String? {
        var best: (language: String, cost: Double)?
        var typable: Set<String> = []
        for layout in layouts {
            guard let code = layout.language, word.allSatisfy({ layout.stroke(for: $0) != nil }) else { continue }
            typable.insert(code)
            guard let language = model?.language(code) else { continue }
            let scalars = word.unicodeScalars.map(\.value)
            guard scalars.allSatisfy(language.isLetter) else { continue }
            let symbols = scalars.map(language.symbol)
            let cost = symbols.withUnsafeBufferPointer(language.cost) / Double(symbols.count)
            if best.map({ cost < $0.cost }) ?? true { best = (code, cost) }
        }
        if let best { return best.language }
        return typable.count == 1 ? typable.first : nil
    }
}
