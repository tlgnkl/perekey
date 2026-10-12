// SPDX-License-Identifier: GPL-3.0-or-later

/// Why a shortcut may not work as the user expects.
public enum ShortcutConflict: Hashable, Sendable {
    /// The shortcut opens Spotlight (⌘Space by default): both would run.
    case spotlight
    /// macOS switches the input source on the shortcut (⌃Space, ⌃⌥Space by
    /// default): the layout would change twice.
    case systemInputSwitch
    /// fn / 🌐 runs its own system action, also switching the input source
    /// by default.
    case globeKey
    /// fn twice starts Dictation.
    case dictation
    /// Shift twice opens Search Everywhere in JetBrains IDEs.
    case jetBrainsSearch
    /// A double-tapped modifier may also be a Raycast or Alfred hotkey.
    case launcherDoubleTap
    /// Another Perekey action already reacts to the same keys.
    case otherAction(HotkeyAction)
}

public enum ShortcutConflicts {
    /// Every known conflict of `trigger` if it is set for `action`.
    /// `bindings` are the current shortcuts; the old one of `action` is ignored.
    /// `system` is what macOS does with its own shortcuts on this Mac.
    public static func check(_ trigger: Trigger, for action: HotkeyAction, among bindings: [HotkeyBinding],
                             system: SystemShortcuts = .macOSDefaults) -> [ShortcutConflict]
    {
        var result = Self.system(trigger, system)
        for binding in bindings where binding.action != action && overlap(trigger, binding.trigger) {
            result.append(.otherAction(binding.action))
        }
        return result
    }

    /// Every known conflict of `voice` as the dictation trigger. `bindings`
    /// are the user's shortcuts as saved; the check sees them as the tap
    /// does (`VoiceTrigger.narrowing(_:)`), so the retype on either Option
    /// key does not clash with a tap of the right one.
    public static func check(voice: VoiceTrigger, among bindings: [HotkeyBinding],
                             system: SystemShortcuts = .macOSDefaults) -> [ShortcutConflict]
    {
        let trigger = voice.shortcut
        var result = Self.system(trigger, system)
        for binding in voice.narrowing(bindings) where overlap(trigger, binding.trigger) {
            result.append(.otherAction(binding.action))
        }
        return result
    }

    static func system(_ trigger: Trigger, _ system: SystemShortcuts) -> [ShortcutConflict] {
        switch trigger {
        case .key:
            if let spotlight = system.spotlight, overlap(trigger, spotlight) { return [.spotlight] }
            if system.inputSwitches.contains(where: { overlap(trigger, $0) }) { return [.systemInputSwitch] }
            return []
        case let .modifiers(chord, taps):
            let onlyFunction = chord.requirements.keys.allSatisfy { $0 == .function }
                && chord.requirements[.function] != nil
            switch taps {
            case .single:
                return onlyFunction ? [.globeKey] : []
            case .double:
                if onlyFunction { return [.dictation] }
                if chord == .shift { return [.jetBrainsSearch, .launcherDoubleTap] }
                return [.launcherDoubleTap]
            }
        }
    }

    /// Whether some press would fire both triggers.
    static func overlap(_ a: Trigger, _ b: Trigger) -> Bool {
        switch (a, b) {
        case let (.key(codeA, modsA), .key(codeB, modsB)):
            return codeA == codeB && modsA.subtracting([.function]) == modsB.subtracting([.function])
        case let (.modifiers(chordA, tapsA), .modifiers(chordB, tapsB)):
            return tapsA == tapsB && allKeySets.contains { chordA.matches($0) && chordB.matches($0) }
        default:
            return false
        }
    }

    private static let allKeySets: [Set<ModifierKey>] = {
        let keys = ModifierKey.allCases
        return (1..<(1 << keys.count)).map { bits in
            Set(keys.indices.filter { bits & (1 << $0) != 0 }.map { keys[$0] })
        }
    }()
}

public extension HotkeyPreset {
    /// The preset with exactly these shortcuts, if any. Order does not matter.
    init?(matching hotkeys: [HotkeyBinding]) {
        guard let preset = Self.allCases.first(where: { Set($0.hotkeys) == Set(hotkeys) }) else { return nil }
        self = preset
    }
}

public extension ModifierKind {
    /// The symbol on Mac keycaps.
    var glyph: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    /// The order macOS menus list modifiers in.
    static let displayOrder: [ModifierKind] = [.function, .control, .option, .shift, .command]
}

public extension ModifierChord {
    /// The parts of the chord in menu order, for display.
    var parts: [(kind: ModifierKind, side: SideRequirement)] {
        ModifierKind.displayOrder.compactMap { kind in requirements[kind].map { (kind, $0) } }
    }
}
