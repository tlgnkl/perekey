// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk

/// A sentence of the other language, typed right before the measured part.
struct Warmup {
    var unit: ParsedUnit
    var script: LetterScript
    /// The tokens joined by a space.
    var text: String { unit.tokens.map(\.text).joined(separator: " ") }
}

/// Turns a unit with the language of each token into the steps of a scenario
/// (docs/eval.md, «Сценарии»), and sets `err` of each token by playing the
/// steps through Null.
struct ScenarioBuilder {
    let manifest: SuiteManifest
    let library: LayoutLibrary
    let typist = Typist()
    let scorer: Scorer

    init(manifest: SuiteManifest, library: LayoutLibrary) {
        self.manifest = manifest
        self.library = library
        scorer = Scorer(library: library)
    }

    /// Text typed on one layout, or the layout the fingers aim at next.
    struct Piece: Hashable {
        var text: String
        var on: String
    }

    /// How the person moves between the layouts.
    enum Switching {
        /// Chooses the layout in the system: a `layout` step.
        case select
        /// Presses the shortcut that toggles: a `hotkey` step.
        case toggle
        /// Does not think of it.
        case none
    }

    /// The pieces of a unit: segments with their aim, a space between tokens
    /// on the aim of the token before it, and the space at the end if the
    /// manifest ends a case with one.
    func pieces(of unit: ParsedUnit) -> [Piece] {
        let aims = unit.aims
        var pieces: [Piece] = []
        for (index, token) in unit.tokens.enumerated() {
            for (segment, aim) in zip(token.segments, aims[index]) { pieces.append(Piece(text: segment.text, on: aim)) }
            let last = index == unit.tokens.count - 1
            if !last || manifest.effectiveEnd == .space {
                pieces.append(Piece(text: " ", on: aims[index].last ?? unit.set.latin))
            }
        }
        return pieces
    }

    /// The steps for the pieces: a switch wherever the aim changes, as
    /// `switching` says. `active` is the layout the person believes is in
    /// force when the first piece begins; the first piece gets no switch when
    /// it is the aim already.
    func steps(_ pieces: [Piece], believing active: String, switching: Switching) -> [Step] {
        var steps: [Step] = []
        var current = active
        for piece in pieces {
            if piece.on != current {
                switch switching {
                case .select: steps.append(.layout(piece.on))
                case .toggle: steps.append(.hotkey(.switchLayout))
                case .none: break
                }
            }
            if case let .type(text, on)? = steps.last, on == piece.on {
                steps[steps.count - 1] = .type(text + piece.text, on: on)
            } else {
                steps.append(.type(piece.text, on: piece.on))
            }
            current = piece.on
        }
        if manifest.effectiveEnd == .return { steps.append(.key(.return, n: nil, mods: nil)) }
        return steps
    }

    /// Builds the case of a unit for one scenario with `err` set, or says why not.
    func build(ref: String, unit: ParsedUnit, scenario: String, warmup: Warmup?) throws -> Result<EvalCase, Drop> {
        let pieces = pieces(of: unit)
        guard let first = pieces.first else { return .failure(.noLetters) }
        let set = unit.set
        var start = first.on
        var believing = first.on
        var switching = Switching.select
        var warmupSteps: [Step]?
        var warmupText = ""
        switch scenario {
        case "clean.cold":
            break
        case "clean.warm", "slip.warm":
            guard let warmup else { return .failure(.noWarmup) }
            guard let warmLayout = set.layout(for: warmup.script), warmLayout != first.on else {
                return .failure(.noWarmup)
            }
            warmupText = warmup.text + " "
            warmupSteps = [.type(warmupText, on: warmLayout)]
            start = warmLayout
            believing = scenario == "clean.warm" ? warmLayout : first.on
        case "slip.cold":
            start = set.other(than: first.on)
        case "stuck", "clean.toggle":
            guard Set(pieces.map(\.on)).count > 1 else { return .failure(.singleScript) }
            switching = scenario == "stuck" ? .none : .toggle
        default:
            throw EvalError.input("unknown scenario \(scenario)")
        }
        let script = steps(pieces, believing: believing, switching: switching)

        var tokens: [TokenSpec] = []
        for token in unit.tokens {
            var tags: [String] = []
            if token.isMixed { tags.append("mixed-token") }
            if token.code { tags.append("code") }
            tokens.append(TokenSpec(t: token.text, lang: set.code(for: token.scripts.first), err: .none,
                                    tags: tags.isEmpty ? nil : tags))
        }
        var caseTags = manifest.tags ?? []
        if unit.scripts.count > 1, !caseTags.contains("mixed") { caseTags.append("mixed") }

        var env: Env?
        if manifest.effectiveSettings != EvalSettings.defaultPreset { env = Env(settings: manifest.effectiveSettings) }
        let key = ref
        var item = EvalCase(
            suite: manifest.suite, scenario: scenario, split: Self.split(suite: manifest.suite, key: key,
                                                                         dev: manifest.split.dev),
            epoch: manifest.epoch, layouts: set.names, start: start, env: env, warmup: warmupSteps, script: script,
            want: warmupText + tokens.map(\.t).joined(separator: " "), tokens: tokens,
            fold: manifest.fold?.compactMap(EvalCase.Fold.init(rawValue:)),
            tags: caseTags.isEmpty ? nil : caseTags,
            meta: ["ref": .string(ref), "source": .string(Self.sourceName(manifest))]
        )
        if item.fold?.isEmpty == true { item.fold = nil }
        item = try item.identified()

        // `err` comes from Null: it is wrong where the layout is.
        let events = try typist.events(for: item, layouts: library)
        let setup = try CaseSetup(item: item, library: library, classifier: nil)
        let null = try SystemName.null.play(setup, events: events)
        var wrong = false
        for index in wrongTokens(item, null: null) {
            item.tokens?[index].err = .layout
            wrong = true
        }
        if wrong, scenario.hasPrefix("clean") { return .failure(.nullWrongInClean) }
        return .success(item)
    }

    /// The measured tokens Null got wrong. With as many tokens as `want`
    /// they stand on their own places (the cheapest alignment pairs them);
    /// otherwise the scorer aligns them. Scoring every case through the
    /// scorer took most of a build.
    func wrongTokens(_ item: EvalCase, null: RunResult) -> [Int] {
        Self.wrongTokens(item, null: null, scorer: scorer)
    }

    static func wrongTokens(_ item: EvalCase, null: RunResult, scorer: Scorer? = nil) -> [Int] {
        let wanted = Tokenizer.tokens(item.want)
        let typed = Tokenizer.tokens(null.text)
        let measured = item.tokens?.count ?? 0
        if typed.count == wanted.count {
            let offset = wanted.count - measured
            return (0..<measured).filter { typed[offset + $0] != wanted[offset + $0] }
        }
        guard let scorer else { return [] }
        let played = scorer.score(item, null: null, out: null)
        return played.measured.enumerated().filter { $0.element.outcome != .ok }.map(\.offset)
    }

    /// `dev` or `test` by the hash of the suite and the key of the unit
    /// (docs/eval.md, «Части»).
    static func split(suite: String, key: String, dev: Int) -> EvalCase.Split {
        FNV1a.hash64(suite + "\u{1F}" + key) % 100 < UInt64(dev) ? .dev : .test
    }

    static func sourceName(_ manifest: SuiteManifest) -> String {
        switch manifest.reader {
        case .tatoeba: "tatoeba"
        case .class: "class.\(manifest.classSpec?.rule.rawValue ?? "?")"
        case .misspellings: "wikipedia-misspellings"
        case .typopairs: "local-typopairs"
        case .stackexchange:
            ((manifest.sources.first ?? "") as NSString).lastPathComponent.replacingOccurrences(of: ".7z", with: "")
        }
    }
}
