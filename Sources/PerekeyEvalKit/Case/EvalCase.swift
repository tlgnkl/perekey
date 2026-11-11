// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// One case of the bench, format v1 (docs/eval.md, «Случай»): what the
/// person's fingers do and the text they meant.
///
/// Optional fields keep whether they were written: a case read and written
/// again gives the same bytes. `CaseCodec` reads and writes the lines.
public struct EvalCase: Hashable, Sendable {
    public static let version = 1

    public var v: Int
    public var id: String
    public var suite: String
    public var scenario: String
    public var split: Split
    public var epoch: Int?
    /// Names of the layout snapshots in eval/layouts/, in system order.
    public var layouts: [String]
    public var start: String
    public var env: Env?
    public var warmup: [Step]?
    public var script: [Step]
    public var want: String
    public var tokens: [TokenSpec]?
    public var scoring: Scoring?
    public var checks: [Check]?
    public var fold: [Fold]?
    public var tags: [String]?
    public var meta: [String: JSONValue]?

    public init(id: String = "", suite: String, scenario: String, split: Split, epoch: Int? = nil,
                layouts: [String], start: String, env: Env? = nil, warmup: [Step]? = nil, script: [Step],
                want: String, tokens: [TokenSpec]? = nil, scoring: Scoring? = nil, checks: [Check]? = nil,
                fold: [Fold]? = nil, tags: [String]? = nil, meta: [String: JSONValue]? = nil)
    {
        v = Self.version
        self.id = id
        self.suite = suite
        self.scenario = scenario
        self.split = split
        self.epoch = epoch
        self.layouts = layouts
        self.start = start
        self.env = env
        self.warmup = warmup
        self.script = script
        self.want = want
        self.tokens = tokens
        self.scoring = scoring
        self.checks = checks
        self.fold = fold
        self.tags = tags
        self.meta = meta
    }

    public enum Split: String, Hashable, Sendable, Codable, CaseIterable {
        case dev, test
    }

    public enum Scoring: String, Hashable, Sendable, Codable {
        /// An outcome for every token.
        case token
        /// Only the whole text and the `checks`.
        case `case`
    }

    /// A fold of the comparison: what counts as equal.
    public enum Fold: String, Hashable, Sendable, Codable {
        /// "ё" and "е" are equal.
        case yo
    }

    public var effectiveEnv: Env { env ?? Env() }
    public var effectiveScoring: Scoring { scoring ?? .token }
    public var effectiveFold: Set<Fold> { Set(fold ?? []) }
    public var effectiveEpoch: Int { epoch ?? 1 }

    /// The prefix of the suites of personal sets (docs/eval.md, «Личные наборы»).
    public static let personalPrefix = "personal."

    /// The case is of a personal set: its words are a person's own.
    public var isPersonal: Bool { suite.hasPrefix(Self.personalPrefix) }

    /// `meta.status` of an incident: `open` or `fixed`.
    public var status: String? { meta?["status"]?.string }
}

/// The surroundings of a case. Every field is optional; `nil` is the default.
public struct Env: Hashable, Sendable {
    public var app: String?
    public var mode: AppMode?
    /// A preset of `EvalSettings`.
    public var settings: String?
    public var field: FieldKind?
    public var pace: Pace?
    public var lag: Int?
    /// Word counts of the app's language prior (`LanguagePrior(counts:)`).
    public var prior: [String: Double]?
    public var exceptions: [String]?
    public var alwaysFix: [String: String]?
    public var secureInput: Bool?

    public typealias FieldKind = EvalDesk.FieldKind

    public init(app: String? = nil, mode: AppMode? = nil, settings: String? = nil, field: FieldKind? = nil,
                pace: Pace? = nil, lag: Int? = nil, prior: [String: Double]? = nil, exceptions: [String]? = nil,
                alwaysFix: [String: String]? = nil, secureInput: Bool? = nil)
    {
        self.app = app
        self.mode = mode
        self.settings = settings
        self.field = field
        self.pace = pace
        self.lag = lag
        self.prior = prior
        self.exceptions = exceptions
        self.alwaysFix = alwaysFix
        self.secureInput = secureInput
    }

    public static let defaultApp = "com.apple.TextEdit"

    public var effectiveApp: String { app ?? Self.defaultApp }
    public var effectiveMode: AppMode { mode ?? .auto }
    public var effectiveSettings: String { settings ?? EvalSettings.defaultPreset }
    public var effectiveField: FieldKind { field ?? .plain }
    public var effectivePace: Pace { pace ?? .calm }
    public var effectiveLag: Int { lag ?? 0 }
}

/// How fast the person types (docs/eval.md, «Темп»).
public enum Pace: String, Hashable, Sendable, Codable, CaseIterable {
    case calm, burst
}

/// One step of a case (docs/eval.md, «Шаги»). The list is closed: an unknown
/// step is an error, not something to skip.
public enum Step: Hashable, Sendable {
    /// Press the keys that type `text` in the layout `on`, the one the
    /// fingers aim at. The layout in force may be another one: that is the mistake.
    case type(String, on: String)
    /// The person chose this layout in the system.
    case layout(String)
    /// The person pressed the shortcut of this action in the case's settings.
    case hotkey(HotkeyName)
    /// A key by name, `n` times, with modifiers.
    case key(KeyName, n: Int?, mods: [ModName]?)
    case click(ClickSpec)
    /// The focus moves; the field is a new one.
    case focus(FocusSpec)
    case mode(AppMode)
    case capsLock(Bool)
    /// ⇧← this many times.
    case select(Int)
    case secureInput(Bool)
    /// A pause in seconds.
    case wait(Double)
    case pace(Pace)
    /// The Undo button of the hint.
    case undo(UndoSpec)

    /// The actions a `hotkey` step may name (`HotkeyAction`).
    public enum HotkeyName: String, Hashable, Sendable, Codable, CaseIterable {
        case switchLayout, convertLastWord, toggleAutoswitch, changeCase, undoLastCorrection

        public var action: HotkeyAction {
            switch self {
            case .switchLayout: .switchLayout
            case .convertLastWord: .convertLastWord
            case .toggleAutoswitch: .toggleAutoswitch
            case .changeCase: .changeCase
            case .undoLastCorrection: .undoLastCorrection
            }
        }
    }

    public enum KeyName: String, Hashable, Sendable, Codable, CaseIterable {
        case backspace, `return`, tab, escape, left, right, up, down, space, enter

        public var keyCode: UInt16 {
            switch self {
            case .backspace: KeyCode.delete
            case .return: KeyCode.return
            case .tab: KeyCode.tab
            case .escape: KeyCode.escape
            case .left: KeyCode.leftArrow
            case .right: KeyCode.rightArrow
            case .up: KeyCode.upArrow
            case .down: KeyCode.downArrow
            case .space: KeyCode.space
            case .enter: KeyCode.keypadEnter
            }
        }
    }

    public enum ModName: String, Hashable, Sendable, Codable, CaseIterable {
        case shift, option, command, control
    }

    public enum ClickSpec: Hashable, Sendable {
        case start, end, hint
        case position(Int)
    }

    public struct FocusSpec: Hashable, Sendable, Codable {
        public var app: String?
        public var secure: Bool?
        public var known: Bool?

        public init(app: String? = nil, secure: Bool? = nil, known: Bool? = nil) {
            self.app = app
            self.secure = secure
            self.known = known
        }

        public var focus: Focus {
            Focus(bundleID: app, isSecureField: secure ?? false, isKnown: known ?? true)
        }
    }

    public enum UndoSpec: String, Hashable, Sendable, Codable {
        case button
    }
}

/// What the case builder knows about one token of the measured part.
public struct TokenSpec: Hashable, Sendable {
    /// The token as meant.
    public var t: String
    /// A language code, or "-".
    public var lang: String
    /// The person's mistake the builder put in.
    public var err: TokenError
    /// Other forms that count as right.
    public var accept: [String]?
    public var tags: [String]?
    /// The weight; 1 when absent.
    public var w: Double?

    public init(t: String, lang: String, err: TokenError = .none, accept: [String]? = nil, tags: [String]? = nil,
                w: Double? = nil)
    {
        self.t = t
        self.lang = lang
        self.err = err
        self.accept = accept
        self.tags = tags
        self.w = w
    }
}

/// The person's mistake in a token, as the case builder put it in.
public enum TokenError: String, Hashable, Sendable, Codable, CaseIterable {
    case none, layout, typo, caps, doublecap, hyphen, yo, abbrev
}

/// A check of a case scored as a whole.
public enum Check: Hashable, Sendable {
    /// The layout in force at the end.
    case layout(String)
    /// How many corrections were shown.
    case corrections(Int)
    /// How many corrections were undone.
    case undone(Int)
}
