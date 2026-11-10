// SPDX-License-Identifier: GPL-3.0-or-later

/// What the machine answered to one event, in short: the disposition and the
/// facts of each effect. A session file keeps it next to the event, and an
/// exact replay (`perekey-eval replay check`) compares it with what the
/// machine answers now. The decisions behind «why?» and the words of an undo
/// report are left out. The original and the replacement of a correction are
/// in, as the hint shows them, and so are the words the user withdrew from
/// always-fix: this is typed text. A session file holds it, and is written
/// only by the recording build (`PEREKEY_RECORD`); the printed report and
/// the `--json` files of `perekey-eval replay` show it only with `--show-words`.
public struct OutputDigest: Hashable, Sendable, Codable {
    public var disposition: Disposition
    public var effects: [EffectDigest]

    public init(disposition: Disposition = .pass, effects: [EffectDigest] = []) {
        self.disposition = disposition
        self.effects = effects
    }

    public init(_ output: Output) {
        disposition = output.disposition
        effects = output.effects.map(EffectDigest.init)
    }
}

/// One `Effect` in short.
public enum EffectDigest: Hashable, Sendable, Codable {
    case selectLayout(LayoutID)
    case retype(RetypeDigest)
    case convertSelection(seq: UInt32)
    case releaseHeld
    case scheduleDeadline(at: Double)
    case autoswitchChanged(Bool)
    case pastePlain
    case refused(String)
    case corrected(CorrectionDigest)
    case correctionUndone(seq: UInt32)
    case correctionUndoFailed(seq: UInt32)
    case undoSettled(UndoDigest)
    case alwaysFixWithdrawn(String)
    case capsLockOff
    case languagesCounted(app: String?, site: String?, words: [String: Int], generation: UInt32)
    case voice(String)
    case typingInterrupted

    public init(_ effect: Effect) {
        switch effect {
        case let .selectLayout(id): self = .selectLayout(id)
        case let .retype(retype): self = .retype(RetypeDigest(retype))
        case let .convertSelection(seq): self = .convertSelection(seq: seq)
        case .releaseHeld: self = .releaseHeld
        case let .scheduleDeadline(at): self = .scheduleDeadline(at: at)
        case let .autoswitchChanged(on): self = .autoswitchChanged(on)
        case .pastePlain: self = .pastePlain
        case let .refused(refusal): self = .refused("\(refusal)")
        case let .corrected(correction): self = .corrected(CorrectionDigest(correction))
        case let .correctionUndone(seq): self = .correctionUndone(seq: seq)
        case let .correctionUndoFailed(seq): self = .correctionUndoFailed(seq: seq)
        case let .undoSettled(report): self = .undoSettled(UndoDigest(report))
        case let .alwaysFixWithdrawn(word): self = .alwaysFixWithdrawn(word)
        case .capsLockOff: self = .capsLockOff
        case let .languagesCounted(tally):
            self = .languagesCounted(app: tally.app, site: tally.site, words: tally.words, generation: tally.generation)
        case let .voice(signal): self = .voice(Self.name(signal))
        case .typingInterrupted: self = .typingInterrupted
        }
    }

    static func name(_ signal: VoiceSignal) -> String {
        switch signal {
        case .toggle: "toggle"
        case .holdBegan: "holdBegan"
        case let .holdEnded(reason): reason == .released ? "holdEnded.released" : "holdEnded.lost"
        case .cancel: "cancel"
        }
    }
}

/// A `Retype` in short: the keys are counted, their text is left out.
public struct RetypeDigest: Hashable, Sendable, Codable {
    public var seq: UInt32
    public var deleteCount: Int
    /// How many keys it types.
    public var keys: Int
    public var target: LayoutID
    /// `automatic.<kind>`, `undo`, `manual.<action>` or `manualSelection.<action>`.
    public var origin: String
    public var viaAccessibility: Bool

    public init(_ retype: Retype) {
        seq = retype.seq
        deleteCount = retype.deleteCount
        keys = retype.keys.count
        target = retype.target
        origin = Self.name(retype.origin)
        viaAccessibility = retype.viaAccessibility
    }

    static func name(_ origin: Retype.Origin) -> String {
        switch origin {
        case let .automatic(kind): "automatic.\(kind)"
        case .undo: "undo"
        case let .manual(action): "manual.\(name(action))"
        case let .manualSelection(action): "manualSelection.\(name(action))"
        }
    }

    static func name(_ action: HotkeyAction) -> String {
        switch action {
        case .switchLayout: "switchLayout"
        case let .selectLanguage(language): "selectLanguage.\(language)"
        case .convertLastWord: "convertLastWord"
        case .toggleAutoswitch: "toggleAutoswitch"
        case .changeCase: "changeCase"
        case .transliterate: "transliterate"
        case .pastePlain: "pastePlain"
        case .undoLastCorrection: "undoLastCorrection"
        }
    }
}

/// A `Correction` in short, with the text the hint shows.
public struct CorrectionDigest: Hashable, Sendable, Codable {
    public var seq: UInt32
    /// `Correction.Kind`: `layout`, `typo`, `yo`…
    public var kind: String
    public var source: LayoutID
    public var target: LayoutID
    public var undoable: Bool
    public var original: String
    public var replacement: String

    public init(_ correction: Correction) {
        seq = correction.seq
        kind = "\(correction.kind)"
        source = correction.source
        target = correction.target
        undoable = correction.undoable
        original = correction.original
        replacement = correction.replacement
    }
}

/// An `UndoReport` without its word.
public struct UndoDigest: Hashable, Sendable, Codable {
    public var channel: UndoChannel
    public var followUp: UndoFollowUp
    public var facts: UndoFacts

    public init(_ report: UndoReport) {
        channel = report.channel
        followUp = report.followUp
        facts = report.facts
    }
}
