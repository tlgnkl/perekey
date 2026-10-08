// SPDX-License-Identifier: GPL-3.0-or-later

import IOKit
import IOKit.hidsystem
import os

/// Turns Caps Lock off after Perekey corrected a word typed with it on by
/// mistake (`Effect.capsLockOff`).
///
/// Sets the lock state of the HID system (`IOHIDSetModifierLockState`),
/// the state the Caps Lock key itself toggles: the light goes off, and
/// the next key types small letters. A posted Caps Lock key event is not
/// reliable: it reaches apps as a change of flags but does not toggle the
/// lock state of the keyboard, so the light stays on and the next key
/// still types capitals; and the key may be remapped (Perekey's own F18
/// remap, Karabiner). Main thread only; needs no permission beyond what
/// Perekey has.
@MainActor
public enum CapsLockState {
    private static let log = Logger(subsystem: "app.perekey", category: "capslock")

    /// Whether Caps Lock is on now; `nil` if the HID system does not answer.
    public static var isOn: Bool? {
        withConnection { connect in
            var state = false
            return IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS
                ? state : nil
        } ?? nil
    }

    /// Turns Caps Lock off if it is on. Returns false if the HID system refused.
    @discardableResult
    public static func turnOff() -> Bool {
        let done = withConnection { connect in
            var state = false
            guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else {
                return false
            }
            guard state else { return true }
            return IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
        } ?? false
        if !done { log.error("Cannot turn Caps Lock off") }
        return done
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return nil
        }
        defer { IOServiceClose(connect) }
        return body(connect)
    }
}
