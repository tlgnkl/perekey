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
    /// Every retype asked for, in order, also after it was posted.
    var history: [Retype] = []
    /// Effects for the app: corrections, undos, learned words, refusals.
    var log: [Effect] = []
    /// Answer the next retypes with `.retypeCancelled`, as a failed caret check.
    var cancelRetypes = false
    /// The app raises the first letter of the word a retype typed at the start
    /// of a sentence, as TextEdit and Notes do with macOS autocapitalization.
    var autocapitalizes = false
    /// What the app does to the word between the caret check and the end of the
    /// Backspaces of a retype. The check reads the field before the Backspaces,
    /// so each of these is a change it cannot see.
    enum Interference: Equatable {
        /// macOS makes the first letter of the word a capital.
        case raisesLetter
        /// The autocorrection finishes: the app puts this text in the word's place.
        case replacesWord(String)
        /// The first `count` Backspaces are eaten (a correction panel takes the key).
        case eatsBackspaces(count: Int)
    }
    var interference: Interference?
    /// How each retype's Backspaces ended, in order.
    var erasures: [Erasure.Outcome] = []
    /// The check after the Backspaces. Off, the retype types blindly, as it did
    /// before that check existed; the tests of it show what that leaves.
    var confirmsErasure = true
    /// Every event the machine handled and what it answered, while not nil:
    /// a session as the recorder writes it (`SessionStep`).
    var tape: [SessionStep]?
    /// The desk hands the machine the buffers it asks for after every event, as
    /// the main thread does; the tests of the buffers themselves turn it off.
    var suppliesPersonalRoom = true
    #if PEREKEY_RECORD
    /// Sees every event the machine handled, its output and the machine
    /// after it, as the engine's typing recorder does (`RecordingBuffer`).
    var watcher: ((InputEvent, Output, InputMachine) -> Void)?
    #endif

    /// The fixture model has no n-grams worth the name: every word costs more
    /// than the real limit of the personal lexicon's words and candidates
    /// (`Classifier.Options.personalNoiseCost`), so the desk runs without it;
    /// `perekey-eval personal` has the real model's say.
    static let classifier: Classifier = {
        var options = Classifier.Options()
        options.personalNoiseCost = .infinity
        return Classifier(model: ModelFixture.model, options: options)
    }()
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

    /// The undos reported for learning (`Effect.undoSettled`).
    var undoReports: [UndoReport] {
        log.compactMap { if case let .undoSettled(report) = $0 { report } else { nil } }
    }

    /// The words of the undos that give evidence: the button and the
    /// shortcuts, and a Backspace the next key showed was meant.
    var learned: [String] {
        undoReports.filter { LearningOptions().weight($0.channel, $0.followUp) > 0 }.map(\.word)
    }

    var withdrawn: [String] {
        log.compactMap { if case let .alwaysFixWithdrawn(word) = $0 { word } else { nil } }
    }

    var undone: [UInt32] {
        log.compactMap { if case let .correctionUndone(seq) = $0 { seq } else { nil } }
    }

    mutating func send(_ event: InputEvent) {
        run(handle(event).effects)
    }

    private mutating func handle(_ event: InputEvent) -> Output {
        let output = machine.handle(event)
        if let recorded = RecordedEvent(event) { tape?.append(SessionStep(event: recorded, output: OutputDigest(output))) }
        // The main thread of the app: it gives the machine the buffers it asks for.
        while suppliesPersonalRoom, machine.judge.personalRoomsWanted > 0 {
            _ = machine.handle(.personalRoomReturned(PersonalRoom()))
        }
        #if PEREKEY_RECORD
        watcher?(event, output, machine)
        #endif
        return output
    }

    mutating func key(_ event: KeyEvent) {
        let output = handle(.key(event, time: time))
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
                history.append(retype)
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
                var retype = retypes.removeFirst()
                // The engine drops a retype whose fence is gone.
                guard machine.pendingRetypeSeq == retype.seq else { continue }
                let before = String(text.suffix(retype.expected.count))
                guard !cancelRetypes, let match = CaretText.match(expected: retype.expected, actual: before) else {
                    send(.retypeCancelled(seq: retype.seq))
                    continue
                }
                if match == .firstLetterRaised { retype = retype.raisingFirstLetter() }
                guard erase(retype, word: before) else {
                    send(.retypeCancelled(seq: retype.seq))
                    continue
                }
                let start = text.count
                text += retype.text
                if autocapitalizes, CaretText.startsSentence(after: text.prefix(start)), let first = text.dropFirst(start).first {
                    text.replaceSubrange(text.index(text.startIndex, offsetBy: start)...text.index(text.startIndex, offsetBy: start),
                                         with: String(first).uppercased())
                }
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

    /// The Backspaces of `retype`, what the app does meanwhile, and the check
    /// after them (`InputEngine.erased`). False: nothing may be typed.
    private mutating func erase(_ retype: Retype, word: String) -> Bool {
        let wordUnits = word.utf16.count
        let start = text.utf16.count - wordUnits
        let snapshot = Erasure.Snapshot(start: start, lead: Self.slice(text, max(0, start - Erasure.Snapshot.leadLength)..<start),
                                        word: word)
        var backspaces = retype.deleteCount
        var eaten = 0
        switch interference {
        case .raisesLetter:
            let index = text.index(text.startIndex, offsetBy: text.count - word.count)
            text.replaceSubrange(index...index, with: String(text[index]).uppercased())
        case let .replacesWord(other):
            text.removeLast(word.count)
            text += other
        case let .eatsBackspaces(count):
            eaten = min(count, backspaces)
            backspaces -= eaten
        case nil:
            break
        }
        guard confirmsErasure else {
            text.removeLast(min(backspaces, text.count))
            return true
        }
        // One Backspace works per pause: the app is a few milliseconds behind.
        var queue = backspaces
        var clock = time
        let outcome = Erasure.confirm(
            snapshot, now: { clock },
            pause: {
                clock += 0.002
                if queue > 0, !text.isEmpty { text.removeLast(); queue -= 1 }
            },
            read: {
                let location = text.utf16.count
                let gap = location - start
                return Erasure.Reading(
                    location: location, lead: Self.slice(text, max(0, start - Erasure.Snapshot.leadLength)..<start),
                    remaining: gap > 0 && gap <= wordUnits ? Self.slice(text, start..<location) : "")
            },
            restore: { text += $0 })
        time = clock
        erasures.append(outcome)
        return outcome == .erased
    }

    private static func slice(_ text: String, _ range: Range<Int>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        let units = Array(text.utf16)
        return String(decoding: units[range.lowerBound..<min(range.upperBound, units.count)], as: UTF16.self)
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
