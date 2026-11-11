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
            secureInput: env.secureInput ?? false, field: env.effectiveField, lag: env.effectiveLag,
            tracesJudgements: setup.tracesJudgements
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
    /// cancelled retypes, and, with the trace of judgements, the words it
    /// kept and the ones it did not judge. In the order of the typist's
    /// events.
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
        // A switch or a correction is in the log with its decision already.
        for judged in desk.judgements {
            switch judged.trace.action {
            case .kept:
                let decision = judged.trace.decision
                entries.append(TraceEntry(
                    event: judged.event, kind: .kept, reason: decision.map { "\($0.reason)" },
                    score: decision.map(\.score).flatMap { $0.isFinite ? $0 : nil }, margin: decision?.margin
                ))
            case let .notJudged(skip):
                entries.append(TraceEntry(event: judged.event, kind: .notJudged, reason: "skip:\(skip.rawValue)"))
            case .switched, .corrected:
                break
            }
        }
        // Stable: entries of one event keep the order they were made in.
        return entries.enumerated().sorted { ($0.element.event, $0.offset) < ($1.element.event, $1.offset) }.map(\.element)
    }
}

/// A field without a layout switcher: what the person gets without Perekey.
/// Keys type in the layout in force; the person's own layout choices, the
/// editing keys and clicks work. The `switchLayout` shortcut of the case's
/// settings works too (the person switches with the system's shortcut
/// instead); no other shortcut does.
///
/// Null is the constant base the outcomes count from, so its shortcut
/// follows the machine's rules: none in the mode `off` (the app takes the
/// shortcuts away, as `EvalDesk` does) and none under Secure Input; Caps
/// Lock and keys break a chord in the machine's order (`InputMachine`,
/// `Shortcuts`).
public struct NullSystem: TypingSystem {
    private var field = TextField()
    private var layout: LayoutMap
    private let layouts: [LayoutMap]
    private var capsLock = false
    private var mode: AppMode
    private var secureInput: Bool
    private let bindings: [HotkeyBinding]
    private var chords: ChordDetector<HotkeyAction>

    public init(setup: CaseSetup) throws {
        layout = setup.start
        layouts = setup.layouts
        let env = setup.item.effectiveEnv
        mode = env.effectiveMode
        secureInput = env.secureInput ?? false
        bindings = setup.settings.hotkeys.filter { $0.action == .switchLayout }
        chords = Self.detector(bindings, mode: mode)
    }

    /// The chords in force: none in "off", as the app removes them.
    private static func detector(_ bindings: [HotkeyBinding], mode: AppMode) -> ChordDetector<HotkeyAction> {
        guard mode != .off else { return ChordDetector(bindings: []) }
        return ChordDetector(bindings: bindings.compactMap { binding in
            if case let .modifiers(chord, taps) = binding.trigger {
                ChordDetector.Binding(chord, taps: taps.rawValue, action: binding.action)
            } else {
                nil
            }
        })
    }

    public mutating func send(_ event: TypistEvent, at time: Double) throws {
        switch event {
        case let .keyDown(keyCode, flags):
            if !secureInput {
                chords.otherInput(at: time)
                // The kinds held, without fn, as `Shortcuts.keyDown` matches them.
                let held = Set(ModifierKind.allCases.filter { $0 != .function && flags & $0.independentFlag != 0 })
                if mode != .off, bindings.contains(where: {
                    if case let .key(code, kinds) = $0.trigger { code == keyCode && kinds.subtracting([.function]) == held }
                    else { false }
                }) {
                    switchLayout()
                    return
                }
            }
            field.press(keyCode, flags: capsLock ? flags | EventFlags.capsLock : flags, in: layout)
        case .keyUp:
            if !secureInput { chords.keyReleased() }
        case let .flags(keyCode, flags):
            guard !secureInput else { return }
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
            guard on != capsLock else { return }
            capsLock = on
            if !secureInput { chords.otherInput(at: time) }
        case let .select(chars):
            // The events of the stand (`EvalDesk`): Shift down, the arrows
            // (other input), Shift up. Without arrows the tap counts.
            let shift: Set<ModifierKey> = [.leftShift]
            if !secureInput { _ = chords.modifiersChanged(to: shift, at: time) }
            for _ in 0..<max(chars, 0) {
                if !secureInput { chords.otherInput(at: time) }
                field.extendLeft()
            }
            if !secureInput, chords.modifiersChanged(to: [], at: time) == .switchLayout { switchLayout() }
        case let .mode(newMode):
            let wasOff = mode == .off
            mode = newMode
            if (newMode == .off) != wasOff { chords = Self.detector(bindings, mode: newMode) }
        case let .secureInput(on):
            secureInput = on
            chords.reset()
        case .undoButton, .idle:
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
