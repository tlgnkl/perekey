// SPDX-License-Identifier: GPL-3.0-or-later

/// One entry of the `hidutil` `UserKeyMapping` property.
public struct KeyRemapping: Hashable, Sendable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    /// HID usages: page 7 (keyboard) in the high bits, usage ID below.
    public static let capsLockUsage: UInt64 = 0x7_0000_0039
    public static let f18Usage: UInt64 = 0x7_0000_006D

    /// Caps Lock → F18, Perekey's entry.
    public static let capsLockToF18 = KeyRemapping(source: capsLockUsage, destination: f18Usage)

    /// `existing` with Caps Lock sent to F18. Other remappings stay as they
    /// are: Karabiner, a Caps Lock → Escape from a dotfile. An existing
    /// remapping of Caps Lock to something else is replaced; the caller warns
    /// about it first.
    public static func adding(_ entry: KeyRemapping, to existing: [KeyRemapping]) -> [KeyRemapping] {
        existing.filter { $0.source != entry.source } + [entry]
    }

    /// `existing` without Perekey's entry, and nothing else removed.
    public static func removing(_ entry: KeyRemapping, from existing: [KeyRemapping]) -> [KeyRemapping] {
        existing.filter { $0 != entry }
    }
}
