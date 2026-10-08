// SPDX-License-Identifier: GPL-3.0-or-later

/// All of Perekey's input logic as a state machine: events in, effects out.
///
/// The system layer only delivers `InputEvent`s and carries out the `Effect`s,
/// so every behavior can be tested on recorded event sequences without a
/// keyboard. `handle(_:)` runs on the event tap thread for every key press:
/// keep it free of I/O, locks and allocations in the common path.
///
/// **The fence.** A layout switch reaches the application asynchronously, so
/// keys typed right after a retype could land in the old layout or between the
/// synthetic keys. After a retype the machine holds user keyboard input until
/// the tap has seen the last synthetic event and the system has confirmed the
/// layout change, or until `Settings.fenceTimeout` has passed. Held events
/// come back as `.replayed` and are handled as usual. A replayed event can
/// start a new retype; the replayed events after it are held again, or they
/// would overtake that retype.
///
/// Clicks cannot be held: the mouse tap only listens, since an active mouse
/// tap would delay all pointer input. A click during the fence reaches the
/// app before the held keys. The fence lasts milliseconds, so this is rare.
public struct InputMachine: Sendable {
    public private(set) var settings: Settings
    public private(set) var buffer = WordBuffer()
    /// The layout Perekey believes is selected: the last one it selected, or
    /// the last one the system reported.
    public private(set) var currentLayout: LayoutID?

    private var detector: ChordDetector<HotkeyAction>
    /// Key triggers, with modifiers as a `kindMask` so matching does not allocate.
    private var keyHotkeys: [(keyCode: UInt16, modifiers: UInt8, action: HotkeyAction)] = []
    private var layouts: [LayoutID: LayoutMap] = [:]
    private var layoutOrder: [LayoutID] = []
    private var previousLayout: LayoutID?
    /// Layouts Perekey selected that the system has not confirmed yet, oldest
    /// first. A late confirmation of an earlier one must not undo a later one.
    private var pendingSelections: [LayoutID] = []
    /// The layout the system last reported as selected.
    private var confirmedLayout: LayoutID?
    private var secureInput = false
    private var focus: Focus?
    private var fence: Fence?
    private var nextSeq: UInt32 = 1
    /// Key ups of keys that ran a shortcut on key down: swallow them too.
    private var swallowedKeyUps: Set<UInt16> = []

    private struct Fence: Sendable {
        var seq: UInt32
        var lastOwnEventSeen = false
        /// The layout whose selection the system has not confirmed yet.
        var awaitedLayout: LayoutID?
        var deadline: Double
        /// The layout to go back to if the retype is cancelled.
        var layoutBefore: LayoutID?
    }

    public init(settings: Settings = Settings(), layouts: [LayoutMap] = [], currentLayout: LayoutID? = nil) {
        self.settings = settings
        detector = ChordDetector(bindings: [])
        apply(settings)
        setLayouts(layouts)
        self.currentLayout = currentLayout
        confirmedLayout = currentLayout
    }

    /// Whether user input is being held back right now.
    public var isHolding: Bool { fence != nil }

    public mutating func handle(_ event: InputEvent) -> Output {
        var effects: [Effect] = []
        let output = handle(event, effects: &effects)
        return Output(output, effects)
    }

    private mutating func handle(_ event: InputEvent, effects: inout [Effect]) -> Disposition {
        switch event {
        case let .key(key, time):
            // A user key that arrives after the deadline joins the held keys,
            // or it would overtake them.
            if expireFence(at: time, effects: &effects), !key.origin.isOwn { return .hold }
            return handleKey(key, at: time, effects: &effects)

        case let .flagsChanged(keyCode, flags, origin, time):
            if expireFence(at: time, effects: &effects), !origin.isOwn { return .hold }
            if case .own = origin { return .pass }
            if fence != nil { return .hold }
            guard !secureInput else { return .pass }
            if keyCode == KeyCode.capsLock {
                detector.otherInput(at: time)
            } else if let action = detector.modifiersChanged(to: Self.modifiers(keyCode: keyCode, flags: flags),
                                                             at: time)
            {
                perform(action, at: time, effects: &effects)
            }
            return .pass

        case let .click(time):
            expireFence(at: time, effects: &effects)
            detector.otherInput(at: time)
            buffer.clear()

        case let .scroll(time):
            detector.otherInput(at: time)

        case let .focusChanged(newFocus):
            focus = newFocus
            buffer.clear()

        case let .layoutChanged(id):
            confirmedLayout = id
            if let index = pendingSelections.firstIndex(of: id) {
                pendingSelections.removeSubrange(...index)
            } else {
                // Someone else switched: the user from the menu, or another app.
                pendingSelections.removeAll()
                if id != currentLayout {
                    if let currentLayout, layouts[currentLayout] != nil { previousLayout = currentLayout }
                    currentLayout = id
                }
            }
            if layouts[id] == nil { buffer.clear() }
            if fence?.awaitedLayout == id {
                fence?.awaitedLayout = nil
                releaseIfDone(effects: &effects)
            }

        case let .layoutsChanged(maps):
            setLayouts(maps)
            buffer.clear()

        case let .secureInputChanged(isOn):
            // Key presses do not reach the tap under Secure Input, but modifier
            // changes do: every capital letter of a password would look like a
            // Shift tap. Keep the detector off until Secure Input ends.
            secureInput = isOn
            detector.reset()
            buffer.clear()
            swallowedKeyUps.removeAll()

        case let .retypeCancelled(seq):
            // The text before the caret was not what the buffer expected, so
            // the buffer is wrong too. Put the layout back and let input go.
            guard let cancelled = fence, cancelled.seq == seq else { break }
            buffer.clear()
            if let layout = cancelled.layoutBefore { select(layout, effects: &effects) }
            release(effects: &effects)

        case let .settingsChanged(newSettings):
            apply(newSettings)

        case .inputLost:
            detector.reset()
            buffer.clear()
            swallowedKeyUps.removeAll()
            release(effects: &effects)

        case let .deadline(time):
            expireFence(at: time, effects: &effects)
        }
        return .pass
    }

    // MARK: - Keys

    private mutating func handleKey(_ key: KeyEvent, at time: Double, effects: inout [Effect]) -> Disposition {
        switch key.origin {
        case let .own(seq, last):
            if last, fence?.seq == seq {
                fence?.lastOwnEventSeen = true
                releaseIfDone(effects: &effects)
            }
            return .pass
        case .user, .replayed:
            if fence != nil { return .hold }
        }
        guard !secureInput else { return .pass }
        detector.otherInput(at: time)

        if key.phase == .up {
            return swallowedKeyUps.remove(key.keyCode) != nil ? .drop : .pass
        }

        // F-keys and arrows always carry the fn bit, so fn never takes part.
        let held = ModifierKind.kindMask(inEventFlags: key.flags) & ~ModifierKind.function.maskBit
        if let hotkey = keyHotkeys.first(where: { $0.keyCode == key.keyCode && $0.modifiers == held }) {
            swallowedKeyUps.insert(key.keyCode)
            if !key.isRepeat { perform(hotkey.action, at: time, effects: &effects) }
            return .drop
        }

        updateBuffer(with: key, held: held)
        return .pass
    }

    private mutating func updateBuffer(with key: KeyEvent, held: UInt8) {
        if held & (ModifierKind.command.maskBit | ModifierKind.control.maskBit) != 0
            || KeyCode.navigation.contains(key.keyCode)
            || focus?.isSecureField == true
        {
            buffer.clear()
            return
        }
        if key.keyCode == KeyCode.delete {
            if held & ModifierKind.option.maskBit != 0 { buffer.clear() } else { buffer.deleteBackward() }
            return
        }
        let stroke = KeyStroke(key.keyCode, LayoutModifiers(eventFlags: key.flags))
        guard let currentLayout, let map = layouts[currentLayout] else {
            buffer.clear()
            return
        }
        if map.isDeadKey(stroke) {
            // A dead key and the next key make one character, so keys and
            // characters no longer match one to one. Give up on this word.
            buffer.abandonWord()
        } else if map.text(for: stroke) != nil {
            buffer.type(stroke, in: currentLayout)
        } else {
            buffer.clear()
        }
    }

    // MARK: - Actions

    private mutating func perform(_ action: HotkeyAction, at time: Double, effects: inout [Effect]) {
        switch action {
        case .switchLayout:
            let next: LayoutID? = if let currentLayout, let index = layoutOrder.firstIndex(of: currentLayout) {
                layoutOrder[(index + 1) % layoutOrder.count]
            } else {
                layoutOrder.first
            }
            if let next { select(next, effects: &effects) }

        case let .selectLanguage(language):
            if let id = layoutOrder.first(where: { layouts[$0]?.language == language }) {
                select(id, effects: &effects)
            }

        case .toggleAutoswitch:
            settings.autoswitch.toggle()
            effects.append(.autoswitchChanged(settings.autoswitch))

        case .convertLastWord:
            retypeWord(at: time, effects: &effects)
        }
    }

    private mutating func select(_ id: LayoutID, effects: inout [Effect]) {
        guard id != currentLayout else { return }
        if let currentLayout, layouts[currentLayout] != nil { previousLayout = currentLayout }
        currentLayout = id
        if pendingSelections.count == 8 { pendingSelections.removeFirst() }
        pendingSelections.append(id)
        effects.append(.selectLayout(id))
    }

    private mutating func retypeWord(at time: Double, effects: inout [Effect]) {
        if focus?.isSecureField == true {
            effects.append(.refused(.secureField))
            return
        }
        guard let source = buffer.wordLayout else {
            effects.append(.convertSelection)
            return
        }
        guard let currentLayout, layouts[currentLayout] != nil,
              let target = counterpart(of: source), let targetMap = layouts[target]
        else {
            effects.append(.refused(.unsupportedLayout))
            return
        }

        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(buffer.entries.count)
        for entry in buffer.entries {
            guard let sourceMap = layouts[entry.layout], let typed = sourceMap.text(for: entry.stroke),
                  !entry.stroke.modifiers.contains(.option)
            else {
                effects.append(.refused(.unconvertibleWord))
                return
            }
            guard let text = targetMap.text(for: entry.stroke) else {
                effects.append(.refused(.missingKeys))
                return
            }
            expected += typed
            keys.append(Retype.Key(stroke: entry.stroke, text: text))
        }

        let seq = nextSeq
        nextSeq = nextSeq == .max ? 1 : nextSeq + 1
        let layoutBefore = target == currentLayout ? nil : currentLayout
        select(target, effects: &effects)
        effects.append(.retype(Retype(deleteCount: keys.count, keys: keys, target: target,
                                      expected: expected, seq: seq)))
        buffer.relabel(to: target)

        let deadline = time + settings.fenceTimeout
        fence = Fence(seq: seq, awaitedLayout: target == confirmedLayout ? nil : target, deadline: deadline,
                      layoutBefore: layoutBefore)
        effects.append(.scheduleDeadline(at: deadline))
    }

    /// The layout a word typed in `source` should be retyped into.
    ///
    /// With two layouts it is simply the other one. With more, prefer the
    /// layout the user just switched to (double Shift switches first, then
    /// retypes), then the one used before, then another language.
    private func counterpart(of source: LayoutID) -> LayoutID? {
        if let currentLayout, currentLayout != source, layouts[currentLayout] != nil { return currentLayout }
        if let previousLayout, previousLayout != source, layouts[previousLayout] != nil { return previousLayout }
        let others = layoutOrder.filter { $0 != source }
        let language = layouts[source]?.language
        return others.first { layouts[$0]?.language != language } ?? others.first
    }

    // MARK: - Fence

    private mutating func releaseIfDone(effects: inout [Effect]) {
        if let fence, fence.lastOwnEventSeen, fence.awaitedLayout == nil { release(effects: &effects) }
    }

    @discardableResult
    private mutating func expireFence(at time: Double, effects: inout [Effect]) -> Bool {
        guard let fence, time >= fence.deadline else { return false }
        release(effects: &effects)
        return true
    }

    private mutating func release(effects: inout [Effect]) {
        guard fence != nil else { return }
        fence = nil
        effects.append(.releaseHeld)
    }

    // MARK: - Setup

    private mutating func apply(_ newSettings: Settings) {
        settings = newSettings
        var chords: [ChordDetector<HotkeyAction>.Binding] = []
        keyHotkeys = []
        for hotkey in newSettings.hotkeys {
            switch hotkey.trigger {
            case let .modifiers(chord, taps):
                chords.append(.init(chord, taps: taps.rawValue, action: hotkey.action))
            case let .key(keyCode, modifiers):
                let mask = modifiers.reduce(UInt8(0)) { $0 | $1.maskBit } & ~ModifierKind.function.maskBit
                keyHotkeys.append((keyCode, mask, hotkey.action))
            }
        }
        detector = ChordDetector(bindings: chords)
    }

    private mutating func setLayouts(_ maps: [LayoutMap]) {
        layoutOrder = maps.map(\.id)
        layouts = Dictionary(maps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The modifiers held after a `flagsChanged` event.
    ///
    /// Reads the device-dependent side bits. Some virtual keyboards and
    /// synthetic events set only the device-independent bits; then the key that
    /// changed gives its side, and other held kinds count as their left key.
    static func modifiers(keyCode: UInt16, flags: UInt64) -> Set<ModifierKey> {
        let pressed = ModifierKey.pressed(inEventFlags: flags)
        guard pressed.isEmpty else { return pressed }
        let changed = ModifierKey(keyCode: keyCode)
        return Set(ModifierKind.held(inEventFlags: flags).map { kind in
            if let changed, changed.kind == kind { return changed }
            return ModifierKey.allCases.first { $0.kind == kind && !$0.isRight }!
        })
    }
}
