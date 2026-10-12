// SPDX-License-Identifier: GPL-3.0-or-later

/// The macOS shortcuts that bear on Perekey's: the ones that switch the input
/// source and the one that opens Spotlight.
///
/// macOS keeps them in `com.apple.symbolichotkeys` (System Settings → Keyboard
/// → Keyboard Shortcuts) and the 🌐 key's action in `com.apple.HIToolbox`.
public struct SystemShortcuts: Hashable, Sendable {
    /// «Select the previous input source», ⌃Space by default.
    public var previousInputSource: Trigger?
    /// «Select next source in Input menu», ⌃⌥Space by default.
    public var nextInputSource: Trigger?
    /// «Show Spotlight search», ⌘Space by default.
    public var spotlight: Trigger?
    /// The 🌐 / fn key is set to «Change Input Source».
    public var globeSwitchesInputSource: Bool

    public init(previousInputSource: Trigger?, nextInputSource: Trigger?, spotlight: Trigger?,
                globeSwitchesInputSource: Bool)
    {
        self.previousInputSource = previousInputSource
        self.nextInputSource = nextInputSource
        self.spotlight = spotlight
        self.globeSwitchesInputSource = globeSwitchesInputSource
    }

    static let controlSpace = Trigger.key(keyCode: KeyCode.space, modifiers: [.control])
    static let controlOptionSpace = Trigger.key(keyCode: KeyCode.space, modifiers: [.control, .option])
    static let commandSpace = Trigger.key(keyCode: KeyCode.space, modifiers: [.command])

    /// A Mac nobody has changed: what `check` assumes without a reading.
    public static let macOSDefaults = SystemShortcuts(previousInputSource: controlSpace,
                                                      nextInputSource: controlOptionSpace,
                                                      spotlight: commandSpace,
                                                      globeSwitchesInputSource: false)

    /// The shortcuts that switch the input source in macOS, in the order to show them.
    public var inputSwitches: [Trigger] {
        let keys = [previousInputSource, nextInputSource].compactMap(\.self)
        let globe = Trigger.modifiers(ModifierChord([.function: .either]), taps: .single)
        return globeSwitchesInputSource ? [globe] + keys : keys
    }

    /// The user chose how macOS switches: changed or turned off the default
    /// shortcuts, or set 🌐 to switch. Such a habit is worth keeping as it is.
    public var isCustomized: Bool {
        globeSwitchesInputSource || previousInputSource != Self.controlSpace
            || nextInputSource != Self.controlOptionSpace
    }

    // MARK: - Reading

    /// One entry of `AppleSymbolicHotKeys`.
    public struct Entry: Hashable, Sendable {
        public var enabled: Bool
        /// `value.parameters`: the character, the virtual key code (65535 for
        /// none) and the modifiers as `NSEvent.ModifierFlags`.
        public var parameters: [Int]

        public init(enabled: Bool, parameters: [Int]) {
            self.enabled = enabled
            self.parameters = parameters
        }
    }

    /// IDs in `AppleSymbolicHotKeys`.
    public enum ID {
        public static let previousInputSource = 60
        public static let nextInputSource = 61
        public static let spotlight = 64
    }

    /// `AppleFnUsageType` value for «Change Input Source».
    public static let fnUsageChangeInputSource = 1

    /// The shortcuts from the stored entries. A missing entry means macOS uses
    /// its default; an entry that is off or has no key means no shortcut.
    public init(symbolicHotKeys entries: [Int: Entry], fnUsageType: Int?) {
        func trigger(_ id: Int, default value: Trigger) -> Trigger? {
            guard let entry = entries[id] else { return value }
            guard entry.enabled, entry.parameters.count >= 3,
                  let keyCode = UInt16(exactly: entry.parameters[1]), keyCode != UInt16.max else { return nil }
            let modifiers = ModifierKind.held(inEventFlags: UInt64(truncatingIfNeeded: entry.parameters[2]))
            return .key(keyCode: keyCode, modifiers: modifiers)
        }
        self.init(previousInputSource: trigger(ID.previousInputSource, default: Self.controlSpace),
                  nextInputSource: trigger(ID.nextInputSource, default: Self.controlOptionSpace),
                  spotlight: trigger(ID.spotlight, default: Self.commandSpace),
                  globeSwitchesInputSource: fnUsageType == Self.fnUsageChangeInputSource)
    }
}
