// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyDesk

/// One thing the bench does to a real app: a `CGEvent` or a choice of layout.
public enum AppAction: Hashable, Sendable {
    case keyDown(code: UInt16, flags: UInt64)
    case keyUp(code: UInt16, flags: UInt64)
    /// A modifier went down or up: `flagsChanged` with the flags in force after it.
    case modifier(code: UInt16, flags: UInt64)
    /// The person chose a layout in the system: the id of the input source (`com.apple.keylayout.Russian`).
    case layout(String)
}

/// What the real app can be given of the events of the typist, and how
/// (docs/eval.md, «Настоящая программа»).
public enum AppActions {
    /// Arrow keys carry these two flags when a person presses them (`kCGEventFlagMaskNumericPad`,
    /// `kCGEventFlagMaskSecondaryFn`); an app that reads them as a plain key ignores the arrow.
    static let arrowFlags: UInt64 = 0x0020_0000 | 0x0080_0000
    static let arrows: Set<UInt16> = [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.downArrow, KeyCode.upArrow]

    private static let leftShiftCode: UInt16 = 56
    private static let leftCommandCode: UInt16 = 55

    /// The actions for one event of the typist; nil for an event the real app cannot be given
    /// (a change of focus or mode, Secure Input, Caps Lock, the button of the hint): the cases that
    /// have it are not played (`AppSupport`).
    public static func actions(for event: TypistEvent) -> [AppAction]? {
        switch event {
        case let .keyDown(code, flags): [.keyDown(code: code, flags: withArrow(code, flags))]
        case let .keyUp(code, flags): [.keyUp(code: code, flags: withArrow(code, flags))]
        case let .flags(code, flags): [.modifier(code: code, flags: flags)]
        case let .userLayout(id): [.layout(id.rawValue)]
        case let .click(target): click(target)
        case let .select(chars): select(chars)
        case .idle: []
        case .focus, .mode, .secureInput, .capsLock, .undoButton: nil
        }
    }

    private static func withArrow(_ code: UInt16, _ flags: UInt64) -> UInt64 {
        arrows.contains(code) ? flags | arrowFlags : flags
    }

    private static func press(_ code: UInt16, flags: UInt64) -> [AppAction] {
        [.keyDown(code: code, flags: withArrow(code, flags)), .keyUp(code: code, flags: withArrow(code, flags))]
    }

    /// A click puts the caret where a mouse would. The bench never moves the mouse: ⌘↑ and ⌘↓ go to the
    /// start and the end of the text, a position is that many ⌘↑ and →. The button of the hint is a
    /// button of Perekey's own window: no key does that.
    private static func click(_ target: ClickTarget) -> [AppAction]? {
        let command = EventFlags.command
        func toEdge(_ code: UInt16) -> [AppAction] {
            [.modifier(code: leftCommandCode, flags: command)] + press(code, flags: command)
                + [.modifier(code: leftCommandCode, flags: 0)]
        }
        switch target {
        case .start: return toEdge(KeyCode.upArrow)
        case .end: return toEdge(KeyCode.downArrow)
        case let .position(position):
            return toEdge(KeyCode.upArrow) + (0..<max(position, 0)).flatMap { _ in press(KeyCode.rightArrow, flags: 0) }
        case .hint: return nil
        }
    }

    /// ⇧← this many times, with Shift held through them.
    private static func select(_ chars: Int) -> [AppAction] {
        let shift = EventFlags.shift
        return [.modifier(code: leftShiftCode, flags: shift)]
            + (0..<max(chars, 0)).flatMap { _ in press(KeyCode.leftArrow, flags: shift) }
            + [.modifier(code: leftShiftCode, flags: 0)]
    }
}

/// Which cases the real app can play, and why not for the rest. A case that is not played is counted
/// under its reason; the run says how many there were of each.
public enum AppSupport {
    /// The reason the case cannot be played in the app `bundle`, or nil when it can.
    /// `enabled` is the set of layouts the system has on (ids of input sources); the case's
    /// layouts must be exactly it, or a shortcut that switches the layout goes round a different ring.
    public static func unsupported(_ item: EvalCase, bundle: String, enabled: Set<String>?, library: LayoutLibrary) -> String? {
        let env = item.effectiveEnv
        if env.effectiveApp != bundle { return "app" }
        if env.effectiveSettings != EvalSettings.defaultPreset { return "settings" }
        if env.effectiveMode != .auto { return "mode" }
        if env.secureInput == true { return "secureInput" }
        if env.prior != nil { return "prior" }
        if !(env.exceptions ?? []).isEmpty || !(env.alwaysFix ?? [:]).isEmpty { return "exceptions" }
        for step in item.allSteps {
            switch step {
            case .focus: return "focus"
            case .mode: return "mode"
            case .secureInput: return "secureInput"
            case .capsLock: return "capsLock"
            case .undo: return "undo"
            case .click(.hint): return "hint"
            default: break
            }
        }
        for check in item.checks ?? [] {
            switch check {
            case .layout: break
            case .corrections, .undone: return "checks"
            }
        }
        if let enabled {
            let ids = Set(item.layouts.compactMap { library[$0]?.id.rawValue })
            if ids != enabled { return "layouts" }
        }
        return nil
    }
}
