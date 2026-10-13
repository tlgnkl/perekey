// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The layout to type in after a dictation: the one of the phrase's main
/// language, not of its last word. "Сделай коммит и отправь изменения в
/// main" ends in English and goes on in Russian; in "открой pull request в
/// main" neither language has the clear lead, and the layout stays.
public enum DictationLanguage {
    /// The share of the counted words the main language needs.
    public static let lead = 2.0 / 3.0

    /// The language of at least `lead` of the words in `text`. A word
    /// counts for the installed layout that can type it and whose language
    /// model finds it likeliest; words no layout types, or that two layouts
    /// type equally well with no model to choose, count for none.
    public static func dominant(in text: String, layouts: [LayoutMap], model: LanguageModel?) -> String? {
        var words: [String: Int] = [:]
        for word in text.split(whereSeparator: { !$0.isLetter }) {
            guard let language = language(of: word.lowercased(), layouts: layouts, model: model) else { continue }
            words[language, default: 0] += 1
        }
        let total = words.values.reduce(0, +)
        guard let top = words.max(by: { $0.value < $1.value }), Double(top.value) >= lead * Double(total) else {
            return nil
        }
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
