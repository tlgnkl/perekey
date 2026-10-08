// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import PerekeyCore

/// Layouts dumped from macOS by `perekey-layout-dump`.
enum Fixture {
    static let abc = layout("ABC")
    static let us = layout("US")
    static let abcExtended = layout("USExtended")
    static let russian = layout("Russian")
    static let russianPC = layout("RussianWin")
    static let ukrainianPC = layout("Ukrainian-PC")

    static func layout(_ name: String) -> LayoutMap {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONDecoder().decode(LayoutMap.self, from: Data(contentsOf: url))
    }
}

extension LayoutMap {
    /// The text these strokes type in this layout.
    func type(_ strokes: [KeyStroke]) -> String {
        strokes.map { text(for: $0)! }.joined()
    }

    /// The strokes that type this text.
    func strokes(_ text: String) -> [KeyStroke] {
        text.map { stroke(for: $0)! }
    }
}

/// Builds event sequences with a running clock.
struct Keyboard {
    var machine: InputMachine
    var time = 100.0

    static let leftShift: UInt64 = EventFlags.shift | ModifierKey.leftShift.eventFlagMask
    static let rightShift: UInt64 = EventFlags.shift | ModifierKey.rightShift.eventFlagMask
    static let leftOption: UInt64 = EventFlags.option | ModifierKey.leftOption.eventFlagMask
    static let leftCommand: UInt64 = EventFlags.command | ModifierKey.leftCommand.eventFlagMask

    init(_ settings: Settings = Settings(), layouts: [LayoutMap] = [Fixture.abc, Fixture.russian],
         current: LayoutID = Fixture.abc.id)
    {
        machine = InputMachine(settings: settings, layouts: layouts, currentLayout: current)
    }

    @discardableResult
    mutating func send(_ event: InputEvent) -> Output {
        machine.handle(event)
    }

    /// Presses and releases a key; returns the key-down output.
    @discardableResult
    mutating func press(_ keyCode: UInt16, flags: UInt64 = 0, origin: EventOrigin = .user) -> Output {
        time += 0.05
        let down = send(.key(KeyEvent(.down, keyCode: keyCode, flags: flags, origin: origin), time: time))
        time += 0.02
        send(.key(KeyEvent(.up, keyCode: keyCode, flags: flags, origin: origin), time: time))
        return down
    }

    /// Types text the way the given layout types it, Shift included.
    mutating func type(_ text: String, in layout: LayoutMap) {
        for stroke in layout.strokes(text) {
            let shift = stroke.modifiers.contains(.shift)
            if shift { modifiers(keyCode: ModifierKey.leftShift.keyCode, flags: Self.leftShift) }
            press(stroke.keyCode, flags: shift ? Self.leftShift : 0)
            if shift { modifiers(keyCode: ModifierKey.leftShift.keyCode, flags: 0) }
        }
    }

    @discardableResult
    mutating func modifiers(keyCode: UInt16, flags: UInt64, origin: EventOrigin = .user) -> Output {
        time += 0.01
        return send(.flagsChanged(keyCode: keyCode, flags: flags, origin: origin, time: time))
    }

    /// Taps a lone modifier after a pause; returns the release output.
    @discardableResult
    mutating func tap(_ key: ModifierKey, flags: UInt64) -> Output {
        time += 0.3
        modifiers(keyCode: key.keyCode, flags: flags)
        time += 0.08
        return modifiers(keyCode: key.keyCode, flags: 0)
    }

    @discardableResult
    mutating func tapOption() -> Output { tap(.leftOption, flags: Self.leftOption) }

    @discardableResult
    mutating func tapShift() -> Output { tap(.leftShift, flags: Self.leftShift) }

    /// Plays the system layer's part after a retype: the synthetic events come
    /// back through the tap and the layout switch is confirmed.
    @discardableResult
    mutating func completeRetype(_ retype: Retype, confirm: Bool = true) -> [Effect] {
        var effects: [Effect] = []
        for index in 0..<(retype.deleteCount + retype.keys.count) {
            let last = index == retype.deleteCount + retype.keys.count - 1
            // Synthetic events come back within microseconds, not at typing speed.
            time += 0.001
            let event = KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: last))
            effects += send(.key(event, time: time)).effects
        }
        if confirm { effects += send(.layoutChanged(retype.target)).effects }
        return effects
    }
}

extension Output {
    var retype: Retype? {
        effects.lazy.compactMap { if case let .retype(retype) = $0 { retype } else { nil } }.first
    }
}
