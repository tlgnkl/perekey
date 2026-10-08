// SPDX-License-Identifier: GPL-3.0-or-later

/// Decides what happens to the word being typed: automatic switching and the
/// word corrections. It answers with a decision; `InputMachine` carries it out.
///
/// **Automatic switching** (docs/classifier.md, «Автопереключение»). The key
/// that ends a word (space, sentence punctuation, Return, Tab) is held, the
/// word is judged by the `Classifier`, and on `.switch(to:)` the word is
/// retyped in the target layout. The held key and everything typed after it
/// come back as `.replayed` once the new layout has reached the app, so they
/// land in it: fast "ghbdtn vbh" gives "привет мир". Inside a word only an
/// impossible prefix ("ghb") switches early: the letters before it are
/// retyped and the key that made it impossible is held.
///
/// **The word-boundary pipeline** (docs/PLAN.md, «Этап 4»): first the layout
/// is decided, then the word in the layout decided for it goes through the
/// word corrections (`correctWord`). A typo in the wrong layout is fixed by
/// the one retype that switches the layout.
struct WordJudge: Sendable {
    /// Whether automatic switching may still act on the word being typed.
    enum Switching: Sendable, Equatable {
        case allowed
        /// Not for the rest of this word: the user undid a correction,
        /// retyped the word by hand, the correction was cancelled, or a
        /// switch inside the word decided it already.
        case suppressed
        /// Suppressed, and a switch inside this word was undone: learn the
        /// whole word at its end.
        case learnAtEnd
    }

    /// What to do at the key that ends the word.
    enum Ruling {
        /// Let the key through; the word stays as typed.
        case keep
        /// Let the key through and learn this word (`Effect.learned`): a
        /// switch inside it was undone.
        case learn(String)
        /// Let the key through and take this word off "Всегда исправлять"
        /// (`Effect.alwaysFixWithdrawn`): a switch inside it to the listed
        /// word was undone.
        case withdraw(String)
        /// Retype the word and hold the key.
        case retype(WordRetype)
    }

    /// An automatic correction of the word in the buffer.
    struct WordRetype {
        var keys: [Retype.Key]
        /// The text the retype replaces.
        var expected: String
        var deleteCount: Int
        var target: LayoutID
        /// What to report once posted. Its `correction.seq` is 0: the one
        /// who starts the retype numbers it.
        var pending: CorrectionUndo.Pending
        /// The keys of the word after the retype, when a word correction
        /// changed them; nil when they are the same keys in `target`.
        var word: [KeyStroke]?
        /// The key held for the retype: it comes back first after the fence.
        var held: Fence.Returning
        /// The buffer's last key is the held one (a switch inside the word):
        /// it leaves the buffer and comes back in the new layout.
        var dropsLastKey = false
        /// The classifier's decision on the word, nil when it did not run.
        var decision: Classifier.Decision?
    }

    /// A word-level correction of the word in its layout (`correctWord`).
    private struct WordFix {
        /// The keys that type the corrected word.
        var strokes: [KeyStroke]
        var kind: Correction.Kind
        /// The word was typed with Caps Lock on by mistake: turn it off.
        var capsLockOff = false
        /// The typo step changed the word: what it changed.
        var typoChange: TypoCorrector.Change?
    }

    /// Everything automatic switching needs, or nothing when it must not act.
    private struct AutoContext {
        var classifier: Classifier
        var typed: LayoutMap
        /// The layout the word goes to: the first candidate until the
        /// classifier picks one.
        var other: LayoutMap
        /// Every layout the word may go to, `other` first
        /// (`LayoutState.automaticCandidates`).
        var candidates: [LayoutMap]
    }

    private(set) var classifier: Classifier?
    /// Typo correction over the model of `classifier`; nil without a model.
    private var typoCorrector: TypoCorrector?
    var appMode: AppMode = .auto
    /// The language of the last judged word: context for the next one.
    private(set) var previousLanguage: String?
    /// The next word starts a sentence (after `. ! ?`, a line end or a focus
    /// change): a capital there is no name. Independent of the word itself.
    private(set) var sentenceStart = true
    /// The word in the buffer was judged at a boundary and nothing was added
    /// since: "hello!" and then a space is not judged twice. Independent of
    /// `switching`: a suppressed word is still judged once, to learn it and
    /// to pass its language on.
    private(set) var judged = false
    /// The language of the word before the one judged last: the context the
    /// judgement had, so «why?» can ask again with the same one. Only read
    /// while `judged`.
    private var contextAtJudge: String?
    private(set) var switching = Switching.allowed

    init(classifier: Classifier?) {
        setClassifier(classifier)
    }

    mutating func setClassifier(_ newClassifier: Classifier?) {
        classifier = newClassifier
        typoCorrector = newClassifier.map { TypoCorrector(model: $0.model) }
        previousLanguage = nil
    }

    // MARK: - What happened to the word

    /// A key that types a character went into the buffer. `startsWord`: it
    /// began a new word, and whatever was decided about the last one is over.
    mutating func typed(startsWord: Bool) {
        if startsWord { switching = .allowed }
        judged = false
    }

    /// Backspace changed the word: judge it again at its end.
    mutating func deleted() {
        judged = false
    }

    /// The key held by a correction at the word's end came back: the word it
    /// ended was judged already.
    mutating func boundaryReplayed() {
        judged = true
    }

    /// The user said which layout the word is in, or a correction of it was
    /// cancelled: leave the rest of it alone. This also drops a pending
    /// `.learnAtEnd`: a retype by hand after an undo inside the word
    /// contradicts the undo, so there is nothing to learn.
    mutating func leaveWordAlone() {
        switching = .suppressed
    }

    /// A correction of the word was undone: the word is back in its layout.
    mutating func wordUndone(language: String?) {
        switching = .suppressed
        judged = true
        previousLanguage = language
    }

    /// The undo of a switch inside the word was posted: learn the word once
    /// it ends.
    mutating func learnAtWordEnd() {
        switching = .learnAtEnd
    }

    /// The text before the caret is unknown now.
    mutating func forgetContext(newField: Bool) {
        previousLanguage = nil
        if newField { sentenceStart = true }
    }

    // MARK: - At the word's end

    /// Whether `key` may end a word `judge` acts on: the cheap checks,
    /// without any lookup in the model. This runs on every key press; ask it
    /// before `judge`, whose arguments the caller may have to copy.
    func mayJudge(endedBy key: KeyEvent, held: UInt8, buffer: WordBuffer, layouts: LayoutState,
                  settings: Settings) -> Bool
    {
        guard autoswitchMayAct(settings) || wordFixMayAct(settings), !judged, let last = buffer.entries.last,
              !last.isSpace,
              held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit | ModifierKind.option.maskBit) == 0
        else { return false }
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        guard let typed = layouts.currentMap else { return false }
        return Self.endsLine(key) || stroke.keyCode == KeyCode.space || Self.isPunctuation(stroke, in: typed)
    }

    /// At a key that ends the word: whether to retype the word and hold the key.
    mutating func judge(endedBy key: KeyEvent, held: UInt8, buffer: WordBuffer, layouts: LayoutState,
                        settings: Settings, focus: Focus?, secureInput: Bool) -> Ruling
    {
        guard mayJudge(endedBy: key, held: held, buffer: buffer, layouts: layouts, settings: settings),
              let last = buffer.entries.last, let typed = layouts.currentMap
        else { return .keep }
        let endsLine = Self.endsLine(key)
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        let auto = autoContext(layouts: layouts, settings: settings, focus: focus, secureInput: secureInput)
        let typo = typoLayout(layouts: layouts, settings: settings, focus: focus, secureInput: secureInput)
        guard auto != nil || typo != nil else { return .keep }
        // Russian letters sit on punctuation keys: the other layout says
        // whether the key ends the word.
        let other = auto?.other ?? layouts.current.flatMap { layouts.counterpart(of: $0) }.flatMap { layouts[$0] }
            ?? typed
        guard endsLine || Self.endsWord(stroke, typed: typed, other: other) else { return .keep }
        if !endsLine, stroke.keyCode != KeyCode.space,
           buffer.entries.dropFirst().contains(where: { $0.stroke.modifiers.contains(.shift) })
        {
            // "ghBdtn!x" may be a password: its symbol is the "!". Wait for the
            // space, where the classifier sees the whole token.
            return .keep
        }
        judged = true
        contextAtJudge = previousLanguage
        // The word after this key starts a sentence after `. ! ?` or a line
        // end. The space after "hello." judges the word again: the period is
        // in the buffer then.
        let startsSentence = endsLine || Self.endsSentence(stroke, in: typed)
            || (stroke.keyCode == KeyCode.space && Self.endsSentence(last.stroke, in: typed))
        defer { sentenceStart = startsSentence }

        if switching != .allowed {
            var ruling = Ruling.keep
            if switching == .learnAtEnd {
                switching = .suppressed
                if let listed = alwaysFixSpelling(buffer, in: other, settings) {
                    // The latest explicit signal wins: withdraw, learn nothing.
                    ruling = .withdraw(listed)
                } else if settings.learnFromUndos,
                   let word = CorrectionUndo.learnable(Self.text(of: buffer.entries, in: typed),
                                                       or: Self.text(of: buffer.entries, in: other))
                {
                    ruling = .learn(word)
                }
            }
            previousLanguage = typed.language
            return ruling
        }
        guard wordIsPlain(buffer, layouts: layouts) else { return .keep }

        // The held key goes back into the text after the word; Return and Tab
        // end the line, so there is nothing to undo after them.
        let boundary: KeyStroke? = endsLine ? nil : stroke
        var decision: Classifier.Decision?
        if var auto {
            let strokes = buffer.entries.lazy.map(\.stroke)
            let context = Classifier.Context(previousLanguage: previousLanguage)
            // The candidates passed the rule of automatic switching in
            // `LayoutState`: one of them is the plain pair.
            let found = auto.candidates.count == 1
                ? auto.classifier.classify(strokes, typed: auto.typed, other: auto.other, context: context)
                : auto.classifier.classify(strokes, typed: auto.typed, candidates: auto.candidates, context: context)
            decision = found
            // The reading the classifier picked, or one on "Всегда исправлять".
            if case let .switch(to: id) = found.verdict, let map = layouts[id] {
                auto.other = map
            } else if auto.candidates.count > 1,
                      let listed = auto.candidates.first(where: { alwaysFixSpelling(buffer, in: $0, settings) != nil })
            {
                auto.other = listed
            }
            let switches = found.verdict == .switch(to: auto.other.id)
            // The other reading is on "Всегда исправлять": its spelling there.
            let listed = alwaysFixSpelling(buffer, in: auto.other, settings)
            // It switches over a keep, but not over a guard or a capital inside the word.
            let forced = !switches && listed != nil && WordRules.overrides(found) && !isMixedCase(buffer, auto)
            if forced || switches {
                if isException(buffer, in: auto.typed, settings) || isException(buffer, in: auto.other, settings)
                    || alwaysFixSpelling(buffer, in: auto.typed, settings) != nil
                {
                    previousLanguage = auto.typed.language
                    return .keep
                }
                // The listed form is what the user wants, spelt as listed
                // ("артем" typed gives "артём"); a forced one gets no word
                // correction on top.
                let spelling = listed.flatMap { Self.spell($0, buffer.entries, in: auto.other) }
                guard var retype = autoRetype(auto, buffer.entries[...], held: boundary, heldKeyCode: key.keyCode,
                                              midWord: false, undoable: !endsLine, corrects: !forced,
                                              spelling: spelling, layouts: layouts, settings: settings)
                else { return .keep }
                // The facts behind «why?», only for the rare word that switches.
                retype.decision = auto.classifier.classify(
                    buffer.entries.lazy.map(\.stroke), typed: auto.typed, other: auto.other,
                    context: Classifier.Context(previousLanguage: contextAtJudge), explaining: true
                )
                // An undo of a switch to a listed word withdraws it from the
                // list instead of learning, whoever decided the switch.
                retype.pending.alwaysFix = listed
                previousLanguage = auto.other.language
                return .retype(retype)
            }
            previousLanguage = found.language
        } else {
            previousLanguage = typed.language
        }
        // The word stays in its layout: fix it there.
        guard let typo, !isException(buffer, in: typo, settings), alwaysFixSpelling(buffer, in: typo, settings) == nil,
              var retype = typoRetype(buffer, in: typo, heldKeyCode: key.keyCode, held: boundary, undoable: !endsLine,
                                      layouts: layouts, settings: settings)
        else { return .keep }
        retype.decision = decision
        return .retype(retype)
    }

    /// What automatic switching decides about the word in the buffer, for the
    /// user who retyped it by hand: «why did it leave this alone?». Asked
    /// again with the context the word had at its end, or the current one
    /// when it was not judged yet. Nil when automatic switching was not
    /// allowed to act here (off, the app's mode, a password field, a word the
    /// user undid or retyped), or never weighs the layout the user chose
    /// (`target`: ru ↔ uk is manual only).
    func decisionForManualRetype(buffer: WordBuffer, layouts: LayoutState, settings: Settings, focus: Focus?,
                                 secureInput: Bool, target: LayoutID) -> Classifier.Decision?
    {
        guard switching == .allowed,
              var auto = autoContext(layouts: layouts, settings: settings, focus: focus, secureInput: secureInput),
              wordIsPlain(buffer, layouts: layouts),
              let chosen = auto.candidates.first(where: { $0.id == target })
        else { return nil }
        // The reading the user picked, not the one the classifier would rank first.
        auto.other = chosen
        var decision = auto.classifier.classify(
            buffer.entries.lazy.map(\.stroke), typed: auto.typed, other: auto.other,
            context: Classifier.Context(previousLanguage: judged ? contextAtJudge : previousLanguage),
            explaining: true
        )
        if decision.verdict == .switch(to: auto.other.id),
           isException(buffer, in: auto.typed, settings) || isException(buffer, in: auto.other, settings)
        {
            // The user's list kept it.
            decision.verdict = .keep
            decision.reason = .kept
        }
        return decision
    }

    /// Whether `insideWord` may act: the cheap checks, as `mayJudge`.
    func mayActInsideWord(buffer: WordBuffer, settings: Settings) -> Bool {
        let count = buffer.entries.count
        return (count == 3 || count == 4) && autoswitchMayAct(settings) && switching == .allowed
            && buffer.entries.last?.isSpace == false
    }

    /// After a letter: switch at once if the word so far cannot start a word
    /// of this layout's language but can of the other's ("ghb"). The letter
    /// is held and comes back in the new layout.
    mutating func insideWord(buffer: WordBuffer, layouts: LayoutState, settings: Settings, focus: Focus?,
                             secureInput: Bool) -> WordRetype?
    {
        let count = buffer.entries.count
        guard mayActInsideWord(buffer: buffer, settings: settings),
              var context = autoContext(layouts: layouts, settings: settings, focus: focus, secureInput: secureInput),
              wordIsPlain(buffer, layouts: layouts),
              let other = Self.onlyPossibleStart(buffer, context)
        else { return nil }
        context.other = other
        guard !isExceptionPrefix(buffer, context, settings), !isAlwaysFixPrefix(buffer, in: context.typed, settings)
        else { return nil }
        let trigger = buffer.entries[count - 1].stroke
        guard var retype = autoRetype(context, buffer.entries.dropLast(), held: trigger, heldKeyCode: trigger.keyCode,
                                      midWord: true, undoable: true, layouts: layouts, settings: settings)
        else { return nil }
        retype.dropsLastKey = true
        // Decided for the whole word: the end of it must not switch it back.
        switching = .suppressed
        return retype
    }

    // MARK: - Gates

    /// The flags that let automatic switching act, without any lookup: the
    /// per-key path checks this first.
    private func autoswitchMayAct(_ settings: Settings) -> Bool {
        settings.autoswitch && appMode == .auto && classifier != nil
    }

    /// The flags that let some word correction act, without any lookup.
    private func wordFixMayAct(_ settings: Settings) -> Bool {
        appMode == .auto && classifier != nil
            && (settings.typoCorrection && typoCorrector != nil || settings.corrections.correctsWords)
    }

    /// Automatic switching may act now, between this layout and its counterpart.
    private func autoContext(layouts: LayoutState, settings: Settings, focus: Focus?,
                             secureInput: Bool) -> AutoContext?
    {
        guard settings.autoswitch, appMode == .auto, !secureInput, let classifier,
              let focus, focus.isKnown, !focus.isSecureField,
              let typed = layouts.currentMap, let other = layouts.automaticCandidates.first
        else { return nil }
        return AutoContext(classifier: classifier, typed: typed, other: other, candidates: layouts.automaticCandidates)
    }

    /// The one candidate whose language can start a word with the strokes so
    /// far while the typed one cannot ("ghb" → "при"). With two that can
    /// (ru and uk share most starts) the end of the word decides.
    private static func onlyPossibleStart(_ buffer: WordBuffer, _ context: AutoContext) -> LayoutMap? {
        var found: LayoutMap?
        for other in context.candidates
            where context.classifier.impossiblePrefix(buffer.entries.lazy.map(\.stroke), typed: context.typed,
                                                      other: other)
        {
            guard found == nil else { return nil }
            found = other
        }
        return found
    }

    /// The current layout, if some word correction may act in it now. The
    /// same gates as automatic switching: never in «manual only» or «off», in
    /// a password field, on an unknown focus or under Secure Input.
    private func typoLayout(layouts: LayoutState, settings: Settings, focus: Focus?,
                            secureInput: Bool) -> LayoutMap?
    {
        guard appMode == .auto, !secureInput, classifier != nil,
              settings.typoCorrection && typoCorrector != nil || WordCorrections.anyOn(settings),
              let focus, focus.isKnown, !focus.isSecureField,
              let typed = layouts.currentMap, typed.language != nil
        else { return nil }
        return typed
    }

    /// Every key of the word typed in the current layout, without ⌥.
    private func wordIsPlain(_ buffer: WordBuffer, layouts: LayoutState) -> Bool {
        guard let current = layouts.current else { return false }
        for entry in buffer.entries where entry.layout != current || entry.stroke.modifiers.contains(.option) {
            return false
        }
        return true
    }

    // MARK: - Retypes

    /// The word `entries` retyped in `context.other`, with a correction to
    /// report once posted. Nil when the word cannot be typed there.
    private func autoRetype(_ context: AutoContext, _ entries: ArraySlice<WordBuffer.Entry>, held: KeyStroke?,
                            heldKeyCode: UInt16, midWord: Bool, undoable: Bool, corrects: Bool = true,
                            spelling: [KeyStroke]? = nil, layouts: LayoutState, settings: Settings) -> WordRetype?
    {
        guard case let .keys(word) = layouts.retypeKeys(for: entries, into: context.other) else { return nil }
        var strokes = entries.map(\.stroke)
        var wordLength = strokes.count
        if let held, context.typed.text(for: held) != nil, context.other.text(for: held) != nil {
            strokes.append(held)
            if midWord { wordLength += 1 }
        }
        // The whole word is known: the word corrections see it in its new layout.
        var keys = word.keys
        var fix: WordFix?
        let spelt = spelling.map { WordFix(strokes: $0, kind: .layout) }
        if !midWord, let found = spelt ?? (corrects ? correctWord(entries, in: context.other, settings: settings) : nil) {
            keys.removeAll(keepingCapacity: true)
            for stroke in found.strokes {
                guard let text = context.other.text(for: stroke) else { return nil }
                keys.append(Retype.Key(stroke: stroke, text: text))
            }
            fix = found
        }
        var pending = CorrectionUndo.Pending(
            correction: Correction(seq: 0, original: "", replacement: "", source: context.typed.id,
                                   target: context.other.id, undoable: undoable, kind: fix?.kind ?? .layout),
            strokes: strokes, wordLength: wordLength, isOpen: midWord, typed: fix?.strokes,
            capsLockOff: fix?.capsLockOff ?? false
        )
        pending.correction.insideWord = midWord
        if midWord {
            // No classifier ran; the decision only names the language.
            pending.correction.decision = Classifier.Decision(verdict: .keep, score: 0, reason: .compared,
                                                              language: nil, typedLanguage: context.typed.language)
        }
        pending.correction.typoChange = fix?.typoChange
        CorrectionUndo.describe(&pending, layouts: layouts)
        return WordRetype(keys: keys, expected: word.expected, deleteCount: word.keys.count,
                          target: context.other.id, pending: pending, word: fix?.strokes,
                          held: .boundary(keyCode: heldKeyCode, endsWord: !midWord))
    }

    /// The word in the buffer corrected in its own layout, as `autoRetype`
    /// does for a switch. Nil when there is nothing to correct.
    private func typoRetype(_ buffer: WordBuffer, in typed: LayoutMap, heldKeyCode: UInt16, held: KeyStroke?,
                            undoable: Bool, layouts: LayoutState, settings: Settings) -> WordRetype?
    {
        guard let fix = correctWord(buffer.entries[...], in: typed, settings: settings) else { return nil }
        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(fix.strokes.count)
        for entry in buffer.entries {
            guard let text = typed.text(for: entry.stroke) else { return nil }
            expected += text
        }
        for stroke in fix.strokes {
            guard let text = typed.text(for: stroke) else { return nil }
            keys.append(Retype.Key(stroke: stroke, text: text))
        }
        var strokes = buffer.entries.map(\.stroke)
        let wordLength = strokes.count
        if let held, typed.text(for: held) != nil { strokes.append(held) }
        var pending = CorrectionUndo.Pending(
            correction: Correction(seq: 0, original: "", replacement: "", source: typed.id,
                                   target: typed.id, undoable: undoable, kind: fix.kind),
            strokes: strokes, wordLength: wordLength, isOpen: false, typed: fix.strokes,
            capsLockOff: fix.capsLockOff
        )
        pending.correction.typoChange = fix.typoChange
        CorrectionUndo.describe(&pending, layouts: layouts)
        return WordRetype(keys: keys, expected: expected, deleteCount: wordLength, target: typed.id,
                          pending: pending, word: fix.strokes, held: .boundary(keyCode: heldKeyCode, endsWord: true))
    }

    /// The word corrections at a word boundary, in order, on the word in the
    /// layout decided for it (`map`). Each step is off by its own setting
    /// and sees the word as the steps before it left it (docs/corrections.md):
    /// 1. Typos: one key off (`TypoCorrector`, `Settings.typoCorrection`).
    ///    First, because the dictionary steps look the word up and want it
    ///    spelt right; the typo corrector works on letters in any case.
    /// 2. The dictionary steps of `WordCorrections`: Caps Lock, double
    ///    capitals, abbreviations, "ё".
    /// The kind of the first step that changed the word names the correction.
    private func correctWord(_ entries: ArraySlice<WordBuffer.Entry>, in map: LayoutMap,
                             settings: Settings) -> WordFix?
    {
        var fix: WordFix?
        if settings.typoCorrection, let typoCorrector,
           let candidate = typoCorrector.correct(entries.lazy.map(\.stroke), in: map, sentenceStart: sentenceStart)
        {
            fix = WordFix(strokes: candidate.strokes, kind: .typo, typoChange: candidate.change)
        }
        guard let model = classifier?.model, WordCorrections.anyOn(settings) else { return fix }
        let strokes = fix?.strokes ?? entries.map(\.stroke)
        var characters: [Character] = []
        characters.reserveCapacity(strokes.count)
        for stroke in strokes {
            guard let text = map.text(for: stroke), text.count == 1, let character = text.first else { return fix }
            characters.append(character)
        }
        var word = BoundaryWord(characters: characters, modifiers: strokes.map(\.modifiers), language: map.language)
        guard WordCorrections.run(&word, settings: settings, model: model), let kind = word.kind else { return fix }
        var corrected: [KeyStroke] = []
        corrected.reserveCapacity(word.characters.count)
        for (index, character) in word.characters.enumerated() {
            // Keep the key the user pressed where it still types the character.
            if index < strokes.count, map.text(for: strokes[index]) == String(character) {
                corrected.append(strokes[index])
            } else if let stroke = map.stroke(for: character), !stroke.modifiers.contains(.option) {
                corrected.append(stroke)
            } else {
                return fix
            }
        }
        return WordFix(strokes: corrected, kind: fix?.kind ?? kind, capsLockOff: word.capsLockOff,
                       typoChange: fix?.typoChange)
    }

    // MARK: - The user's list

    /// The word is on the user's list as this layout reads it.
    private func isException(_ buffer: WordBuffer, in map: LayoutMap, _ settings: Settings) -> Bool {
        guard !settings.exceptions.isEmpty, let word = Self.text(of: buffer.entries, in: map) else { return false }
        return settings.exceptions.contains(Self.exceptionKey(word))
    }

    /// Some word on the user's list starts with the word so far, in either
    /// reading: do not switch it early.
    private func isExceptionPrefix(_ buffer: WordBuffer, _ context: AutoContext, _ settings: Settings) -> Bool {
        guard !settings.exceptions.isEmpty else { return false }
        for map in [context.typed, context.other] {
            guard let word = Self.text(of: buffer.entries, in: map) else { continue }
            let prefix = Self.exceptionKey(word)
            if settings.exceptions.contains(where: { $0.hasPrefix(prefix) }) { return true }
        }
        return false
    }

    /// The always-fix spelling of the word as this layout reads it, if it is
    /// on the list (`WordRules.matchKey`: "ё" as "е").
    private func alwaysFixSpelling(_ buffer: WordBuffer, in map: LayoutMap, _ settings: Settings) -> String? {
        guard !settings.alwaysFix.isEmpty, let word = Self.text(of: buffer.entries, in: map) else { return nil }
        return settings.alwaysFix[WordRules.matchKey(Self.exceptionKey(word))]
    }

    /// A capital inside the word, next to small letters, in either reading:
    /// the classifier's `mixedCase` guard, which it does not reach for a
    /// typed reading with a symbol inside ("[jhJij"). No list overrides it.
    private func isMixedCase(_ buffer: WordBuffer, _ context: AutoContext) -> Bool {
        for map in [context.typed, context.other] {
            guard let word = Self.text(of: buffer.entries, in: map) else { continue }
            let core = Self.core(of: word)
            if core.dropFirst().contains(where: \.isUppercase), core.contains(where: \.isLowercase) { return true }
        }
        return false
    }

    /// Some always-fix word starts with the word so far as typed: do not
    /// switch it away early.
    private func isAlwaysFixPrefix(_ buffer: WordBuffer, in map: LayoutMap, _ settings: Settings) -> Bool {
        guard !settings.alwaysFix.isEmpty, let word = Self.text(of: buffer.entries, in: map) else { return false }
        let prefix = WordRules.matchKey(Self.exceptionKey(word))
        return settings.alwaysFix.keys.contains { $0.hasPrefix(prefix) }
    }

    /// The keys that type `spelling` in `map` in place of the word's core,
    /// keeping the case the user typed and the keys around the core. Nil when
    /// the keys type it already, or when it cannot be typed one key per letter.
    static func spell(_ spelling: String, _ entries: [WordBuffer.Entry], in map: LayoutMap) -> [KeyStroke]? {
        var strokes: [KeyStroke] = []
        var characters: [Character] = []
        for entry in entries {
            guard !entry.isSpace, let text = map.text(for: entry.stroke), text.count == 1, let character = text.first
            else { return nil }
            strokes.append(entry.stroke)
            characters.append(character)
        }
        guard let start = characters.firstIndex(where: isWordPart) else { return nil }
        var changed = false
        for (offset, wanted) in spelling.enumerated() {
            let index = start + offset
            guard index < characters.count else { return nil }
            let now = characters[index]
            guard now.lowercased() != String(wanted) else { continue }
            let cased = now.isUppercase ? Character(wanted.uppercased()) : wanted
            guard let stroke = map.stroke(for: cased), !stroke.modifiers.contains(.option) else { return nil }
            strokes[index] = stroke
            changed = true
        }
        return changed ? strokes : nil
    }

    static func text(of entries: [WordBuffer.Entry], in map: LayoutMap) -> String? {
        var text = ""
        for entry in entries where !entry.isSpace {
            guard let typed = map.text(for: entry.stroke) else { return nil }
            text += typed
        }
        return text
    }

    /// The word as `WordRules` stores it, without the punctuation around it.
    static func exceptionKey(_ word: String) -> String {
        WordRules.normalize(String(core(of: word)))
    }

    /// The word without the punctuation around it.
    static func core(of word: String) -> Substring {
        var text = Substring(word)
        while let first = text.first, !isWordPart(first) { text.removeFirst() }
        while let last = text.last, !isWordPart(last) { text.removeLast() }
        return text
    }

    private static func isWordPart(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Word ends

    /// Return and Tab end the line, not only the word.
    static func endsLine(_ key: KeyEvent) -> Bool {
        key.keyCode == KeyCode.return || key.keyCode == KeyCode.tab || key.keyCode == KeyCode.keypadEnter
    }

    /// Whether the stroke ends a sentence in this layout: `. ! ? …`.
    static func endsSentence(_ stroke: KeyStroke, in map: LayoutMap) -> Bool {
        guard !stroke.modifiers.contains(.option), let text = map.text(for: stroke) else { return false }
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return false }
        switch scalar.value {
        case 0x2E, 0x21, 0x3F, 0x2026: return true
        default: return false
        }
    }

    /// Whether the stroke types sentence punctuation in this layout:
    /// `. , ! ? ; : " ) » …`. Symbols of code and URLs (`/ @ - _ =`) are not:
    /// they stay in the token, and the classifier keeps it at the next space.
    static func isPunctuation(_ stroke: KeyStroke, in map: LayoutMap) -> Bool {
        guard !stroke.modifiers.contains(.option), let text = map.text(for: stroke) else { return false }
        var scalars = text.unicodeScalars.makeIterator()
        guard let scalar = scalars.next(), scalars.next() == nil else { return false }
        switch scalar.value {
        case 0x2E, 0x2C, 0x21, 0x3F, 0x3B, 0x3A, 0x22, 0x29, 0xBB, 0x2026: return true
        default: return false
        }
    }

    /// Whether a key ends the word typed before it: a space, or punctuation in
    /// the typed layout that is no letter or digit in the other one. "," on the
    /// ABC keys is "б" in Russian, so it stays in the word ("ghbdtn," may be
    /// "приветб"); Shift+1 is "!" in both and ends it.
    static func endsWord(_ stroke: KeyStroke, typed: LayoutMap, other: LayoutMap) -> Bool {
        if stroke.keyCode == KeyCode.space { return true }
        guard isPunctuation(stroke, in: typed) else { return false }
        guard let otherText = other.text(for: stroke) else { return true }
        return !otherText.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }
}
