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

    /// The modifiers held according to an event's flags.
    ///
    /// Read the state from every event instead of counting presses and releases:
    /// a missed event (tap disabled, Secure Input) would otherwise leave a key
    /// "stuck" forever.
    static func pressed(inEventFlags flags: UInt64) -> Set<ModifierKey> {
        Set(allCases.filter { flags & $0.eventFlagMask != 0 })
    }
}
