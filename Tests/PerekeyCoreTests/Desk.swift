// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyCore

/// The machine with a text field and a lazy system layer around it.
///
/// The app types each passed key in `appLayout`, the layout that has reached
/// it. Held keys wait in `held` and come back as `.replayed` on
/// `.releaseHeld`. Layout selections and retypes wait for `settle()`, the
/// main thread catching up: until then the app keeps typing in the old
/// layout. A machine that let keys through too early would show it in `text`.
struct Desk {
    var machine: InputMachine
    var time = 100.0
    var text = ""
    var appLayout: LayoutID
    let maps: [LayoutID: LayoutMap]
    var held: [KeyEvent] = []
    var selected: LayoutID?
    var retypes: [Retype] = []
    /// Effects for the app: corrections, undos, learned words, refusals.
    var log: [Effect] = []
    /// Answer the next retypes with `.retypeCancelled`, as a failed caret check.
    var cancelRetypes = false

    static let classifier = Classifier(model: ModelFixture.model)
    static let textEdit = Focus(bundleID: "com.apple.TextEdit")

    init(_ settings: Settings = Settings(), layouts: [LayoutMap] = [Fixture.abc, Fixture.russian],
         current: LayoutID = Fixture.abc.id, classifier: Classifier? = Desk.classifier,
         focus: Focus? = Desk.textEdit)
    {
        machine = InputMachine(settings: settings, layouts: layouts, currentLayout: current, classifier: classifier)
        appLayout = current
        maps = Dictionary(uniqueKeysWithValues: layouts.map { ($0.id, $0) })
        if let focus { send(.focusChanged(focus)) }
    }

    var corrections: [Correction] {
        log.compactMap { if case let .corrected(correction) = $0 { correction } else { nil } }
    }

    var learned: [String] {
        log.compactMap { if case let .learned(word) = $0 { word } else { nil } }
    }

    var undone: [UInt32] {
        log.compactMap { if case let .correctionUndone(seq) = $0 { seq } else { nil } }
    }

    mutating func send(_ event: InputEvent) {
        run(machine.handle(event).effects)
    }

    mutating func key(_ event: KeyEvent) {
        let output = machine.handle(.key(event, time: time))
        switch output.disposition {
        case .pass:
            if event.phase == .down, !event.origin.isOwn { typeIntoApp(event) }
        case .hold:
            held.append(event)
        case .drop:
            break
        }
        run(output.effects)
    }

    private mutating func typeIntoApp(_ event: KeyEvent) {
        switch event.keyCode {
        case KeyCode.delete:
            if !text.isEmpty { text.removeLast() }
        case KeyCode.return, KeyCode.keypadEnter:
            text += "\n"
        case KeyCode.tab:
            text += "\t"
        default:
            let stroke = KeyStroke(event.keyCode, LayoutModifiers(eventFlags: event.flags))
            if event.flags & (EventFlags.command | EventFlags.control) == 0,
               let typed = maps[appLayout]?.text(for: stroke)
            {
                text += typed
            }
        }
    }

    private mutating func run(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .selectLayout(id):
                selected = id
            case let .retype(retype):
                retypes.append(retype)
            case .releaseHeld:
                let events = held
                held.removeAll()
                for var event in events {
                    event.origin = .replayed
                    time += 0.0005
                    key(event)
                }
            case .scheduleDeadline:
                break
            default:
                log.append(effect)
            }
        }
    }

    /// The main thread and the app catch up: retypes are posted, the
    /// synthetic keys pass the tap, the layout reaches the app.
    mutating func settle() {
        while selected != nil || !retypes.isEmpty {
            if !retypes.isEmpty {
                let retype = retypes.removeFirst()
                // The engine drops a retype whose fence is gone.
                guard machine.pendingRetypeSeq == retype.seq else { continue }
                if cancelRetypes || !text.hasSuffix(retype.expected) {
                    send(.retypeCancelled(seq: retype.seq))
                    continue
                }
                text.removeLast(retype.deleteCount)
                text += retype.text
                time += 0.001
                send(.retypePosted(seq: retype.seq, time: time))
                let count = retype.deleteCount + retype.keys.count
                for index in 0..<count {
                    time += 0.0001
                    key(KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: index == count - 1)))
                }
            }
            if let id = selected {
                selected = nil
                appLayout = id
                send(.layoutChanged(id))
            }
        }
    }

    /// Presses and releases a key the way a person does.
    mutating func press(_ keyCode: UInt16, flags: UInt64 = 0, settling: Bool = true) {
        time += 0.05
        key(KeyEvent(.down, keyCode: keyCode, flags: flags))
        time += 0.02
        key(KeyEvent(.up, keyCode: keyCode, flags: flags))
        if settling { settle() }
    }

    /// Presses the keys that type `text` in `layout`. Without `settling` the
    /// main thread lags behind the whole time, as with fast scripted typing.
    mutating func type(_ text: String, on layout: LayoutMap = Fixture.abc, settling: Bool = true) {
        for stroke in layout.strokes(text) {
            let flags: UInt64 = stroke.modifiers.contains(.shift) ? Keyboard.leftShift : 0
            press(stroke.keyCode, flags: flags, settling: settling)
        }
    }

    mutating func tap(_ key: ModifierKey, flags: UInt64) {
        time += 0.3
        send(.flagsChanged(keyCode: key.keyCode, flags: flags, origin: .user, time: time))
        time += 0.08
        send(.flagsChanged(keyCode: key.keyCode, flags: 0, origin: .user, time: time))
        settle()
    }

    mutating func tapOption() { tap(.leftOption, flags: Keyboard.leftOption) }
    mutating func tapShift() { tap(.leftShift, flags: Keyboard.leftShift) }
}
