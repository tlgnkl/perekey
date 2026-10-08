// SPDX-License-Identifier: GPL-3.0-or-later

/// The shortcuts that change text the user asked for: retype the word or the
/// phrase in the other layout, change its case, convert or transliterate the
/// selection. Each answers with a `Plan`; `InputMachine` carries it out.
struct ManualActions: Sendable {
    /// The transform a shortcut applies to the selection.
    enum SelectionAction: Sendable {
        /// Retype in the other layout (`convertLastWord`).
        case convertLayout
        /// Next case of the cycle (`changeCase`).
        case changeCase
        /// Other script (`transliterate`).
        case transliterate

        /// The shortcut that runs it.
        var hotkeyAction: HotkeyAction {
            switch self {
            case .convertLayout: .convertLastWord
            case .changeCase: .changeCase
            case .transliterate: .transliterate
            }
        }
    }

    /// What a shortcut does.
    enum Plan {
        case refuse(Refusal)
        /// Nothing typed: read the selection, then transform it.
        case readSelection(SelectionAction)
        case retype(ManualRetype)
    }

    /// A retype of the word or phrase before the caret.
    struct ManualRetype {
        var word: (keys: [Retype.Key], expected: String)
        var target: LayoutID
        /// What the buffer holds after it.
        var edit: BufferEdit
        /// Into another layout: wait for it to reach the app, and leave the
        /// word alone, since the user said which layout it is in. A case
        /// change keeps the layout and does neither.
        var changesLayout: Bool
        /// The first press on a word, whose automatic decision is worth
        /// explaining; not a phrase or the press that puts a word back.
        var explainable = false
    }

    /// The same keys after a retype, as the buffer must hold them.
    enum BufferEdit {
        /// The word, in another layout.
        case relabel(LayoutID)
        /// The phrase, each key in its new layout.
        case relabelPhrase([WordBuffer.Entry])
        /// The word, as other strokes in the same layout.
        case replaceStrokes([KeyStroke])
    }

    /// What a selection becomes once read.
    enum SelectionPlan {
        /// Let input go, with this refusal if there is one.
        case refuse(Refusal?)
        case retype(target: LayoutID, keys: [Retype.Key])
    }

    /// Repeated presses of the retype shortcut.
    ///
    /// With more than one candidate layout (docs/PLAN.md, stage 8, «Ручной
    /// перенабор при N раскладках») the presses first walk the readings of
    /// the word, most plausible first, and then put it back. With phrases
    /// on (`TextCorrections.phraseRetype`) odd presses after that retype,
    /// even ones put the text back: the first press retypes the last word,
    /// the second puts it back (as without phrases), the third retypes the
    /// last two words, the fourth puts them back, and so on, up to
    /// `WordBuffer.historyWords` words before the last one. Two layouts
    /// have one reading to walk, so nothing changes for them.
    private struct PhraseRetype: Sendable {
        /// How many words the last press took.
        var words: Int
        /// The words are retyped now; the next press puts them back.
        var retyped: Bool
        /// The layout the phrase is retyped into: the first reading of the
        /// last word.
        var target: LayoutID
        /// The layouts the word goes through, press by press, and which of
        /// them it is in now.
        var walk: [LayoutID]
        var step = 0
        /// The keys of those words as the user typed them, spaces included.
        /// `nil` after the first press: the last word, all in `source`. The
        /// tap thread then keeps no copy of the buffer for a single retype.
        var original: [WordBuffer.Entry]?
        /// The layout the last word was typed in.
        var source: LayoutID
    }

    /// The retype shortcut was the last thing done: its next press goes on
    /// with the phrase. Any key, click, other action or focus change ends it.
    private var phrase: PhraseRetype?

    mutating func endPhrase() {
        phrase = nil
    }

    // MARK: - The word before the caret

    /// The retype shortcut: the word in the other layout, the phrase on
    /// repeated presses, or the selection when nothing is typed.
    mutating func retypeWord(buffer: WordBuffer, layouts: LayoutState, phrases: Bool,
                             isSecureField: Bool, classifier: Classifier? = nil) -> Plan
    {
        if isSecureField { return .refuse(.secureField) }
        let previous = phrase
        phrase = nil
        if let previous, let plan = continuePhrase(previous, buffer: buffer, layouts: layouts, phrases: phrases) {
            return plan
        }
        guard let source = buffer.wordLayout else { return .readSelection(.convertLayout) }
        guard let current = layouts.current, layouts[current] != nil,
              let walk = Self.walk(of: buffer, from: source, layouts: layouts, classifier: classifier),
              let target = walk.first, let targetMap = layouts[target]
        else { return .refuse(.unsupportedLayout) }
        switch layouts.retypeKeys(for: buffer.entries, into: targetMap) {
        case let .refused(refusal):
            return .refuse(refusal)
        case let .keys(word):
            let original = buffer.entries.allSatisfy { $0.layout == source } ? nil : buffer.entries
            phrase = PhraseRetype(words: 1, retyped: true, target: target, walk: walk, original: original,
                                  source: source)
            return .retype(ManualRetype(word: word, target: target, edit: .relabel(target), changesLayout: true,
                                        explainable: true))
        }
    }

    /// The layouts the word typed in `source` goes through on repeated
    /// presses: the layout the user switched to first, it is their choice;
    /// the other candidates by how plausible the word reads in them
    /// (`Classifier.ranked`), in `LayoutState` order without a model. Only
    /// layouts of the source's language: the one `counterpart` names.
    private static func walk(of buffer: WordBuffer, from source: LayoutID, layouts: LayoutState,
                             classifier: Classifier?) -> [LayoutID]?
    {
        let candidates = layouts.candidates(of: source)
        guard candidates.count > 1 else {
            return candidates.isEmpty ? layouts.counterpart(of: source).map { [$0] } : candidates
        }
        var fixed: [LayoutID] = []
        var rest = candidates
        if let current = layouts.current, current == candidates[0], current != source {
            fixed = [current]
            rest.removeFirst()
        }
        guard rest.count > 1, let classifier, let typed = layouts[source] else { return fixed + rest }
        let ranked = classifier.ranked(buffer.entries.lazy.map(\.stroke), typed: typed,
                                       candidates: rest.compactMap { layouts[$0] })
        return fixed + ranked.map(\.id)
    }

    /// The next press of the retype shortcut on a phrase: put the words
    /// back, or retype them and one word more. Nil when the buffer no
    /// longer holds them; the press then works as a first one.
    private mutating func continuePhrase(_ state: PhraseRetype, buffer: WordBuffer, layouts: LayoutState,
                                         phrases: Bool) -> Plan?
    {
        // Without phrases and with one reading, a press is a first one: it
        // retypes the word from where it is now, back to the source.
        guard phrases || state.walk.count > 1 else { return nil }
        guard let shown = buffer.phrase(words: state.words) else { return nil }
        let original = state.original ?? shown.map { WordBuffer.Entry($0.stroke, in: state.source) }
        guard shown.count == original.count else { return nil }
        if state.retyped, state.words == 1, state.step + 1 < state.walk.count {
            // The next reading of the word.
            let target = state.walk[state.step + 1]
            let next = shown.map { WordBuffer.Entry($0.stroke, in: target) }
            guard let keys = Self.phraseKeys(shown, becoming: next, layouts: layouts) else {
                return .refuse(.unconvertibleWord)
            }
            var walked = state
            walked.step += 1
            walked.original = original
            phrase = walked
            return .retype(ManualRetype(word: keys, target: target, edit: .relabelPhrase(next), changesLayout: true))
        }
        if state.retyped {
            // Even press: the words as the user typed them.
            guard let keys = Self.phraseKeys(shown, becoming: original, layouts: layouts),
                  let layout = original.last(where: { !$0.isSpace })?.layout
            else { return nil }
            phrase = PhraseRetype(words: state.words, retyped: false, target: state.target, walk: state.walk,
                                  original: original, source: state.source)
            return .retype(ManualRetype(word: keys, target: layout, edit: .relabelPhrase(original),
                                        changesLayout: true))
        }
        guard phrases else { return nil }
        // Odd press: one word more, all in the target layout. With no word
        // before, the same words again.
        let words = state.words < WordBuffer.historyWords + 1 && buffer.phrase(words: state.words + 1) != nil
            ? state.words + 1 : state.words
        guard let span = buffer.phrase(words: words) else { return nil }
        let retyped = span.map { WordBuffer.Entry($0.stroke, in: state.target) }
        guard let keys = Self.phraseKeys(span, becoming: retyped, layouts: layouts) else {
            return .refuse(.unconvertibleWord)
        }
        phrase = PhraseRetype(words: words, retyped: true, target: state.target, walk: [state.target], original: span,
                              source: state.source)
        return .retype(ManualRetype(word: keys, target: state.target, edit: .relabelPhrase(retyped),
                                    changesLayout: true))
    }

    /// The keys that turn the text of `shown` into that of `new`: the same
    /// keys, each typing its text in its new layout. `nil` when a key was
    /// typed with ⌥ or one of the layouts does not type it.
    private static func phraseKeys(_ shown: [WordBuffer.Entry], becoming new: [WordBuffer.Entry],
                                   layouts: LayoutState) -> (keys: [Retype.Key], expected: String)?
    {
        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(new.count)
        for (now, next) in zip(shown, new) {
            guard now.stroke == next.stroke, !now.stroke.modifiers.contains(.option),
                  let typed = layouts[now.layout]?.text(for: now.stroke),
                  let text = layouts[next.layout]?.text(for: next.stroke)
            else { return nil }
            expected += typed
            keys.append(Retype.Key(stroke: next.stroke, text: text))
        }
        return (keys, expected)
    }

    /// Cycles the case of the word before the caret by retyping it with the
    /// same keys and the Shift flags of the new case, in the layout it was
    /// typed in. Without a word, the selection goes through the same cycle.
    static func changeCase(buffer: WordBuffer, layouts: LayoutState, isSecureField: Bool) -> Plan {
        if isSecureField { return .refuse(.secureField) }
        guard let wordLayout = buffer.wordLayout else { return .readSelection(.changeCase) }
        guard let current = layouts.current, wordLayout == current, let map = layouts[current] else {
            return .refuse(.unsupportedLayout)
        }
        var typed: [Character] = []
        typed.reserveCapacity(buffer.entries.count)
        for entry in buffer.entries {
            guard entry.layout == current, !entry.stroke.modifiers.contains(.option),
                  let text = map.text(for: entry.stroke), text.count == 1, let character = text.first
            else { return .refuse(.unconvertibleWord) }
            typed.append(character)
        }
        let old = String(typed)
        guard let new = TextCase.next(after: old) else { return .refuse(.unconvertibleWord) }
        var keys: [Retype.Key] = []
        var strokes: [KeyStroke] = []
        keys.reserveCapacity(typed.count)
        strokes.reserveCapacity(typed.count)
        for (entry, character) in zip(buffer.entries, new) {
            var stroke = entry.stroke
            if map.text(for: stroke) != String(character) {
                guard let other = map.stroke(for: character), !other.modifiers.contains(.option) else {
                    return .refuse(.missingKeys)
                }
                stroke = other
            }
            strokes.append(stroke)
            keys.append(Retype.Key(stroke: stroke, text: String(character)))
        }
        return .retype(ManualRetype(word: (keys, old), target: current, edit: .replaceStrokes(strokes),
                                    changesLayout: false))
    }

    // MARK: - The selection

    /// The selected text arrived: what the shortcut makes of it.
    static func selectionRead(_ text: String, action: SelectionAction, layouts: LayoutState) -> SelectionPlan {
        let candidates = layouts.selectionCandidates()
        switch action {
        case .convertLayout:
            let result = SelectionConversion.convert(text, layouts: candidates) { source in
                layouts.counterpart(of: source).flatMap { layouts[$0] }
            }
            guard case let .keys(source, keys) = result, let target = layouts.counterpart(of: source) else {
                if case let .refused(refusal) = result { return .refuse(refusal) }
                return .refuse(nil)
            }
            return .retype(target: target, keys: keys)
        case .changeCase:
            return transform(text, as: TextCase.next(after:), candidates: candidates, typedIn: .source)
        case .transliterate:
            return transform(text, as: Transliteration.convert, candidates: candidates, typedIn: .result)
        }
    }

    /// Which text decides the layout a transformed selection is typed in.
    private enum LayoutChoice { case source, result }

    /// Types `transform(text)` over the selection, on the layout that types
    /// the source text (case) or the result (script).
    private static func transform(_ text: String, as transform: (String) -> String?, candidates: [LayoutMap],
                                  typedIn: LayoutChoice) -> SelectionPlan
    {
        guard !text.isEmpty else { return .refuse(.nothingSelected) }
        guard SelectionConversion.isTypable(text), let new = transform(text), new != text,
              let map = SelectionConversion.sourceLayout(of: typedIn == .source ? text : new, among: candidates)
        else { return .refuse(.unsupportedSelection) }
        return .retype(target: map.id, keys: SelectionConversion.keys(typing: new, in: map))
    }
}
