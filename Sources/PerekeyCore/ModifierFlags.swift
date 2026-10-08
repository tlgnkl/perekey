// SPDX-License-Identifier: GPL-3.0-or-later

public extension ModifierKey {
    /// Device-dependent bit of this key in `CGEventFlags` (see IOKit `IOLLEvent.h`).
    var eventFlagMask: UInt64 {
        switch self {
        case .leftControl: 0x0000_0001 // NX_DEVICELCTLKEYMASK
        case .leftShift: 0x0000_0002 // NX_DEVICELSHIFTKEYMASK
        case .rightShift: 0x0000_0004 // NX_DEVICERSHIFTKEYMASK
        case .leftCommand: 0x0000_0008 // NX_DEVICELCMDKEYMASK
        case .rightCommand: 0x0000_0010 // NX_DEVICERCMDKEYMASK
        case .leftOption: 0x0000_0020 // NX_DEVICELALTKEYMASK
        case .rightOption: 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .rightControl: 0x0000_2000 // NX_DEVICERCTLKEYMASK
        case .function: 0x0080_0000 // NX_SECONDARYFNMASK
        }
    }

    /// Virtual key code of this key (`kVK_*` in Carbon `Events.h`).
    var keyCode: UInt16 {
        switch self {
        case .leftCommand: 55
        case .leftShift: 56
        case .leftOption: 58
        case .leftControl: 59
        case .rightShift: 60
        case .rightOption: 61
        case .rightControl: 62
        case .function: 63
        case .rightCommand: 54
        }
    }

    /// The modifier key with this virtual key code, if any.
    /// Caps Lock (57) is not a modifier here: treat it as other input.
    init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The modifiers held according to the flags of a `flagsChanged` event.
    ///
    /// Read the state from every `flagsChanged` event instead of counting presses
    /// and releases: a missed event (tap disabled, Secure Input) would otherwise
    /// leave a key "stuck" forever.
    ///
    /// Call this for `flagsChanged` only. Arrow and function keys set
    /// `NX_SECONDARYFNMASK` on their `keyDown`, which would read as a held fn.
    /// Some synthetic events and virtual keyboards set no side bits at all; fall
    /// back to `init(keyCode:)` of the event's key code in that case.
    static func pressed(inEventFlags flags: UInt64) -> Set<ModifierKey> {
        Set(allCases.filter { flags & $0.eventFlagMask != 0 })
    }
}
