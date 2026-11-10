// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// Perekey in memory: `InputMachine` inside `EvalDesk`, with the run's
/// classifier (docs/eval.md, «Испытуемые»).
public struct MachineSystem: TypingSystem {
    public private(set) var desk: EvalDesk

    public init(setup: CaseSetup) throws {
        let env = setup.item.effectiveEnv
        let prior = env.prior.map { LanguagePrior(counts: $0) }
        desk = EvalDesk(EvalDesk.Setup(
            settings: setup.settings, layouts: setup.layouts, start: setup.start.id, classifier: setup.classifier,
            focus: Focus(bundleID: env.effectiveApp), mode: env.effectiveMode, prior: prior,
            secureInput: env.secureInput ?? false, field: env.effectiveField, lag: env.effectiveLag
        ))
    }

    /// Records every call of the machine, for `perekey-eval case`.
    public var recording: Bool {
        get { desk.recording }
        set { desk.recording = newValue }
    }

    public mutating func send(_ event: TypistEvent, at time: Double) throws {
        desk.send(event, at: time)
    }

    public mutating func finish() throws -> RunResult {
        desk.finish()
        return RunResult(text: desk.text, layout: desk.appLayout, corrections: desk.corrections.count,
                         undone: desk.undone.count, trace: Self.trace(of: desk))
    }

    /// What the machine said about its actions: corrections, undos and
    /// cancelled retypes, in the order of the typist's events.
    static func trace(of desk: EvalDesk) -> [TraceEntry] {
        var entries: [TraceEntry] = []
        for logged in desk.log {
            switch logged.effect {
            case let .corrected(correction):
                let decision = correction.decision
                entries.append(TraceEntry(
                    event: logged.event, kind: correction.kind == .layout ? .switched : .corrected,
                    correction: "\(correction.kind)", reason: decision.map { "\($0.reason)" },
                    score: decision.map(\.score).flatMap { $0.isFinite ? $0 : nil }, margin: decision?.margin,
                    insideWord: correction.insideWord
                ))
            case .correctionUndone:
                entries.append(TraceEntry(event: logged.event, kind: .undone))
            default:
                break
            }
        }
        for cancelled in desk.cancelled where cancelled.origin.isAutomatic {
            entries.append(TraceEntry(event: cancelled.event, kind: .cancelled))
        }
        return entries.sorted { $0.event < $1.event }
    }
}

/// A field without a layout switcher: what the person gets without Perekey.
/// Keys type in the layout in force; the person's own layout choices, the
/// editing keys and clicks work. The `switchLayout` shortcut works too (the
/// person switches with the system's shortcut instead); no other shortcut does.
public struct NullSystem: TypingSystem {
    private var field = TextField()
    private var layout: LayoutMap
    private let layouts: [LayoutMap]
    private var capsLock = false
    private var chords: ChordDetector<HotkeyAction>
    private let keyTriggers: [(keyCode: UInt16, kinds: Set<ModifierKind>)]

    public init(setup: CaseSetup) throws {
        layout = setup.start
        layouts = setup.layouts
        let bindings = setup.settings.hotkeys.filter { $0.action == .switchLayout }
        chords = ChordDetector(bindings: bindings.compactMap { binding in
            if case let .modifiers(chord, taps) = binding.trigger {
                ChordDetector.Binding(chord, taps: taps.rawValue, action: binding.action)
            } else {
                nil
            }
        })
        keyTriggers = bindings.compactMap { binding in
            if case let .key(keyCode, kinds) = binding.trigger { (keyCode, kinds) } else { nil }
        }
    }

    public mutating func send(_ event: TypistEvent, at time: Double) throws {
        switch event {
        case let .keyDown(keyCode, flags):
            chords.otherInput(at: time)
            let held = Set(ModifierKind.allCases.filter { flags & $0.independentFlag != 0 })
            if keyTriggers.contains(where: { $0.keyCode == keyCode && $0.kinds == held }) {
                switchLayout()
                return
            }
            field.press(keyCode, flags: capsLock ? flags | EventFlags.capsLock : flags, in: layout)
        case .keyUp:
            chords.keyReleased()
        case let .flags(keyCode, flags):
            if keyCode == KeyCode.capsLock {
                chords.otherInput(at: time)
            } else if chords.modifiersChanged(to: ModifierKey.pressed(inEventFlags: flags), at: time) == .switchLayout {
                switchLayout()
            }
        case let .userLayout(id):
            if let map = layouts.first(where: { $0.id == id }) { layout = map }
        case let .click(target):
            chords.otherInput(at: time)
            switch target {
            case .start: field.place(caret: 0)
            case .end: field.placeAtEnd()
            case let .position(position): field.place(caret: position)
            case .hint: break
            }
        case .focus:
            field = TextField()
        case let .capsLock(on):
            capsLock = on
            chords.otherInput(at: time)
        case let .select(chars):
            for _ in 0..<max(chars, 0) { field.extendLeft() }
        case .mode, .secureInput, .undoButton, .idle:
            break
        }
    }

    /// The next layout of the case, in system order.
    private mutating func switchLayout() {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layout = layouts[(index + 1) % layouts.count]
    }

    public mutating func finish() throws -> RunResult {
        RunResult(text: field.text, layout: layout.id)
    }
}

/// The ideal: the text the person meant. For checking cases and the scorer.
public struct OracleSystem: TypingSystem {
    private let want: String
    private let layout: LayoutID

    public init(setup: CaseSetup) throws {
        want = setup.item.want
        layout = setup.start.id
    }

    public mutating func send(_ event: TypistEvent, at time: Double) throws {}

    public mutating func finish() throws -> RunResult {
        RunResult(text: want, layout: layout)
    }
}
