// SPDX-License-Identifier: GPL-3.0-or-later

/// The modifiers that change which character a key types.
public struct LayoutModifiers: OptionSet, Hashable, Sendable, Codable {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = LayoutModifiers(rawValue: 1 << 0)
    public static let capsLock = LayoutModifiers(rawValue: 1 << 1)
    public static let option = LayoutModifiers(rawValue: 1 << 2)

    /// Every combination, fewest modifiers first: plain, then Shift before Caps Lock.
    public static let allCombinations: [LayoutModifiers] = (0..<8).map { LayoutModifiers(rawValue: $0) }

    /// The layout modifiers of a `CGEventFlags` value.
    public init(eventFlags flags: UInt64) {
        self = []
        if flags & EventFlags.shift != 0 { insert(.shift) }
        if flags & EventFlags.capsLock != 0 { insert(.capsLock) }
        if flags & EventFlags.option != 0 { insert(.option) }
    }
}

/// One physical key press as a layout sees it: the key and the modifiers that
/// select its character. The same stroke types different text in different layouts:
/// key 5 types "g" in ABC and "п" in Russian.
public struct KeyStroke: Hashable, Sendable, Codable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: LayoutModifiers

    public init(_ keyCode: UInt16, _ modifiers: LayoutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var description: String { "\(keyCode)/\(modifiers.rawValue)" }
}

/// Device-independent `CGEventFlags` masks (IOKit `IOLLEvent.h`).
public enum EventFlags {
    public static let capsLock: UInt64 = 0x0001_0000
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000
}

/// Virtual key codes that matter to the input logic (`kVK_*` in Carbon `Events.h`).
public enum KeyCode {
    public static let `return`: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let capsLock: UInt16 = 57
    public static let keypadEnter: UInt16 = 76
    public static let home: UInt16 = 115
    public static let pageUp: UInt16 = 116
    public static let forwardDelete: UInt16 = 117
    public static let end: UInt16 = 119
    public static let pageDown: UInt16 = 121
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126

    /// Keys that move the caret or end the line: the text before the caret is
    /// no longer the word Perekey remembers.
    public static let navigation: Set<UInt16> = [
        `return`, tab, escape, keypadEnter, home, pageUp, forwardDelete, end, pageDown,
        leftArrow, rightArrow, downArrow, upArrow,
    ]
}
