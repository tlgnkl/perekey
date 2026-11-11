// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// The target text of a case: what its steps would give if every `type`
/// came out in its own layout `on`, with the editing keys, clicks and
/// selections, and nothing else (docs/eval.md, «Проверка случая»).
public enum TargetText {
    public static func render(_ steps: [Step], into field: inout TextField) {
        // Caps Lock turned on by a step: the letters typed after it come out in capitals, as the
        // person's keyboard prints them. Only the steps of one list are followed.
        var capsLock = false
        for step in steps {
            switch step {
            case let .type(text, _):
                field.insert(capsLock ? text.uppercased() : text)
            case let .key(name, n, mods):
                let option = mods?.contains(.option) ?? false
                let shift = mods?.contains(.shift) ?? false
                let command = mods?.contains(.command) ?? false || mods?.contains(.control) ?? false
                for _ in 0..<max(n ?? 1, 0) {
                    switch name {
                    case .backspace: option ? field.deleteWordLeft() : field.backspace()
                    case .return, .enter: field.insert("\n")
                    case .tab: field.insert("\t")
                    case .space: if !command { field.insert(" ") }
                    case .left: shift ? field.extendLeft() : field.moveLeft()
                    case .right: field.moveRight()
                    case .up: field.place(caret: 0)
                    case .down: field.placeAtEnd()
                    case .escape: break
                    }
                }
            case let .click(target):
                switch target {
                case .start: field.place(caret: 0)
                case .end: field.placeAtEnd()
                case let .position(position): field.place(caret: position)
                case .hint: break
                }
            case let .select(count):
                for _ in 0..<max(count, 0) { field.extendLeft() }
            case .focus:
                field = TextField()
            case let .capsLock(on):
                capsLock = on
            case .layout, .hotkey, .mode, .secureInput, .wait, .pace, .undo:
                break
            }
        }
    }

    /// The target of the warm-up and of the whole case.
    public static func of(_ item: EvalCase) -> (warmup: String, full: String) {
        var field = TextField()
        render(item.warmup ?? [], into: &field)
        let warmup = field.text
        render(item.script, into: &field)
        return (warmup, field.text)
    }
}

public extension EvalCase {
    /// How many tokens of `want` belong to the warm-up: as many as the
    /// target of the warm-up has.
    var warmupTokenCount: Int { Tokenizer.tokens(TargetText.of(self).warmup).count }

    /// The tokens of `want` after the warm-up: the measured part.
    var measuredWant: [String] { Array(Tokenizer.tokens(want).dropFirst(warmupTokenCount)) }

    /// Every step, the warm-up first.
    var allSteps: [Step] { (warmup ?? []) + script }
}

/// The checks of a case before it is played (docs/eval.md, «Проверка
/// случая»). A case with problems is not played.
public enum CaseCheck {
    /// The problems of a case. Without `reveal`, a case of the test part is
    /// described without its words (rule 2.8).
    public static func problems(_ item: EvalCase, layouts: LayoutLibrary, reveal: Bool = false) -> [String] {
        let hidden = (item.split == .test && !reveal) || item.isPersonal
        func quote(_ text: some StringProtocol) -> String { hidden ? RunFiles.hiddenText : "\"\(text)\"" }
        var problems: [String] = []
        if item.v != EvalCase.version { problems.append("format version \(item.v)") }
        do {
            let computed = try item.computedID()
            if item.id != computed { problems.append("id \(item.id) is not the hash of the content: \(computed)") }
        } catch {
            problems.append(hidden ? "cannot hash the content" : "cannot hash the content: \(error)")
        }
        if item.suite.isEmpty || item.scenario.isEmpty { problems.append("empty suite or scenario") }

        // 5. Layouts.
        for name in item.layouts where layouts[name] == nil { problems.append("unknown layout \(name)") }
        if !item.layouts.contains(item.start) { problems.append("start \(item.start) is not among the layouts") }
        if Set(item.layouts).count != item.layouts.count { problems.append("a layout is listed twice") }

        // A tag reaches the slices and the report: in a personal case it is a word of the person's own at worst.
        if item.isPersonal {
            let tags = (item.tags ?? []) + (item.tokens ?? []).flatMap { $0.tags ?? [] }
            if tags.contains(where: { !SessionCases.allowedTags.contains($0) }) {
                problems.append("a personal case carries a tag outside the allowed ones")
            }
        }

        // The environment.
        let env = item.effectiveEnv
        let settings = EvalSettings.preset(env.effectiveSettings)
        if settings == nil { problems.append("unknown settings preset \(env.effectiveSettings)") }
        if env.effectiveLag < 0 { problems.append("negative lag") }

        // 2. Every character of every `type` is typed in its `on`, and every
        // step names what the case has.
        for (index, step) in item.allSteps.enumerated() {
            switch step {
            case let .type(text, on):
                guard item.layouts.contains(on), let map = layouts[on] else {
                    problems.append("step \(index): layout \(on) is not among the layouts")
                    continue
                }
                for character in text where LayoutLibrary.printableStroke(character, in: map) == nil {
                    problems.append("step \(index): \(on) does not type \(quote(String(character))) without ⌥")
                }
            case let .layout(name):
                if !item.layouts.contains(name) { problems.append("step \(index): layout \(name) is not among the layouts") }
            case let .hotkey(name):
                if let settings, !settings.hotkeys.contains(where: { $0.action == name.action }) {
                    problems.append("step \(index): \(name.rawValue) has no shortcut in \(env.effectiveSettings)")
                }
            case let .key(_, n, _):
                if let n, n < 1 { problems.append("step \(index): n must be at least 1") }
            case let .select(count):
                if count < 1 { problems.append("step \(index): select at least 1") }
            case let .wait(seconds):
                if !(seconds >= 0) { problems.append("step \(index): negative wait") }
            case .click, .focus, .mode, .capsLock, .secureInput, .pace, .undo:
                break
            }
        }

        // 3 and 4. The target text against the tokens and `want`.
        if item.effectiveScoring == .token, item.tokens == nil { problems.append("scoring token needs tokens") }
        if let tokens = item.tokens {
            let target = TargetText.of(item)
            let warmupCount = Tokenizer.tokens(target.warmup).count
            let measuredTarget = Array(Tokenizer.tokens(target.full).dropFirst(warmupCount))
            let measuredWant = item.measuredWant
            if measuredWant.count != tokens.count {
                problems.append("want has \(measuredWant.count) measured tokens, tokens has \(tokens.count)")
            }
            if tokens.contains(where: { $0.err == .hyphen }) {
                problems += alignedProblems(typed: measuredTarget, tokens: tokens, quote: quote)
            } else if measuredTarget.count != tokens.count {
                problems.append("the steps give \(measuredTarget.count) measured tokens, tokens has \(tokens.count)")
            } else {
                for (index, (typed, spec)) in zip(measuredTarget, tokens).enumerated() {
                    let same = typed == spec.t
                    switch spec.err {
                    case .none, .layout:
                        if !same { problems.append("token \(index): the steps give \(quote(typed)), not \(quote(spec.t))") }
                    default:
                        if same { problems.append("token \(index): err \(spec.err.rawValue), but nothing differs") }
                    }
                }
            }
            for (index, (meant, spec)) in zip(measuredWant, tokens).enumerated() where meant != spec.t {
                problems.append("token \(index): want has \(quote(meant)), tokens has \(quote(spec.t))")
            }
            let joined = target.warmup + tokens.map(\.t).joined(separator: " ")
            if joined != item.want, Tokenizer.tokens(joined) != Tokenizer.tokens(item.want) {
                problems.append("want is not the warm-up and the tokens joined by spaces")
            }
        }
        return problems
    }

    /// The tokens of a case with a hyphen error, against the tokens the steps give. A hyphen typed as a space
    /// splits a word, so such a token takes as many typed tokens as it needs until the letters match; every
    /// other token stands against one typed token, hyphens and all.
    static func alignedProblems(typed: [String], tokens: [TokenSpec], quote: (String) -> String) -> [String] {
        func letters(_ text: some StringProtocol) -> String { String(text.filter { $0 != "-" && !$0.isWhitespace }) }
        var problems: [String] = []
        var position = 0
        for (index, spec) in tokens.enumerated() {
            guard position < typed.count else {
                problems.append("token \(index): the steps give no token for it")
                return problems
            }
            if spec.err == .hyphen {
                let wanted = letters(spec.t)
                var taken: [String] = []
                var joined = ""
                while position < typed.count, joined.count < wanted.count {
                    taken.append(typed[position])
                    joined += letters(typed[position])
                    position += 1
                }
                if joined != wanted {
                    problems.append("token \(index): the steps give \(quote(taken.joined(separator: " "))), other letters than \(quote(spec.t))")
                } else if taken == [spec.t] {
                    problems.append("token \(index): err hyphen, but nothing differs")
                }
            } else {
                let text = typed[position]
                position += 1
                let same = text == spec.t
                switch spec.err {
                case .none, .layout:
                    if !same { problems.append("token \(index): the steps give \(quote(text)), not \(quote(spec.t))") }
                default:
                    if same { problems.append("token \(index): err \(spec.err.rawValue), but nothing differs") }
                }
            }
        }
        if position < typed.count { problems.append("the steps give \(typed.count - position) tokens more than the tokens") }
        return problems
    }
}
