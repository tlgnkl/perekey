// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import IOKit.hidsystem
import PerekeyCore

/// Remaps Caps Lock to F18 for the "instant" Caps Lock mode.
///
/// Uses the HID event system's `UserKeyMapping` property, the same one
/// `hidutil property --set` writes. It lives until logout or restart, so
/// Perekey removes its entry when it quits and on launch after a crash.
/// Other entries are read first and kept: someone else's remapping is not
/// Perekey's to drop.
public enum CapsLockRemapper {
    private static var mappingKey: CFString { kIOHIDUserKeyUsageMapKey as CFString }
    private static let sourceKey = kIOHIDKeyboardModifierMappingSrcKey
    private static let destinationKey = kIOHIDKeyboardModifierMappingDstKey

    /// The remappings in effect now.
    public static func currentMappings() -> [KeyRemapping] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let value = IOHIDEventSystemClientCopyProperty(client, mappingKey),
              let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let source = (entry[sourceKey] as? NSNumber)?.uint64Value,
                  let destination = (entry[destinationKey] as? NSNumber)?.uint64Value else { return nil }
            return KeyRemapping(source: source, destination: destination)
        }
    }

    /// Whether Perekey's Caps Lock → F18 entry is in effect.
    public static var isRemapped: Bool {
        currentMappings().contains(.capsLockToF18)
    }

    /// A remapping of Caps Lock that is not Perekey's, e.g. to Escape.
    /// Turning on the instant mode replaces it: ask the user first.
    public static var foreignCapsLockRemap: KeyRemapping? {
        currentMappings().first { $0.source == KeyRemapping.capsLockUsage && $0 != .capsLockToF18 }
    }

    /// Karabiner-Elements grabs the keyboard and applies its own rules first;
    /// a Caps Lock rule there wins over Perekey's.
    @MainActor
    public static var isKarabinerRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("org.pqrs.") == true }
    }

    /// Adds Perekey's entry in `.instant` mode and removes it otherwise.
    /// Returns false if the system refused the change.
    @discardableResult
    public static func apply(_ mode: CapsLockMode) -> Bool {
        let current = currentMappings()
        let wanted = mode == .instant ? KeyRemapping.adding(.capsLockToF18, to: current)
            : KeyRemapping.removing(.capsLockToF18, from: current)
        guard wanted != current else { return true }
        return write(wanted)
    }

    private static func write(_ mappings: [KeyRemapping]) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let entries = mappings.map { [sourceKey: NSNumber(value: $0.source), destinationKey: NSNumber(value: $0.destination)] }
        return IOHIDEventSystemClientSetProperty(client, mappingKey, entries as CFArray)
    }
}
