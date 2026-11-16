// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import PerekeyCore

/// Turns a `Retype` into synthetic key events and posts them.
///
/// Every key event carries both the key code and the Unicode text: apps that
/// read key codes (Java, VMs, remote desktops) get the right key, everyone
/// else gets the text. Flags are only Shift and Caps Lock of the original
/// stroke, never ⌥⌘⌃: a held ⌥ would turn Backspace into ⌥⌫.
///
/// Posted to `.cghidEventTap`, so the events pass through Perekey's own tap
/// and the fence sees the last one. `CGEventPostToPid` would bypass the tap.
public enum TextSink {
    /// Which strokes of the retype. A retype with a check after its Backspaces
    /// posts them in two parts (`Erasure`); the mark of the last event belongs
    /// to the second.
    public enum Part: Sendable {
        case all
        /// The Backspaces, none of them the last event of the retype.
        case erase
        /// The keys of the new text, the last one the last event of the retype.
        case type
    }

    public static func events(for retype: Retype, source: CGEventSource?, part: Part = .all) -> [CGEvent] {
        var strokes: [(keyCode: UInt16, flags: CGEventFlags, text: String?)] = []
        strokes.reserveCapacity(retype.deleteCount + retype.keys.count)
        if part != .type {
            for _ in 0..<retype.deleteCount {
                strokes.append((KeyCode.delete, [], nil))
            }
        }
        for key in retype.keys where part != .erase {
            var flags: CGEventFlags = []
            if key.stroke.modifiers.contains(.shift) { flags.insert(.maskShift) }
            if key.stroke.modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
            strokes.append((key.stroke.keyCode, flags, key.text))
        }

        var events: [CGEvent] = []
        events.reserveCapacity(strokes.count * 2)
        for (index, stroke) in strokes.enumerated() {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: down)
                else { continue }
                event.flags = stroke.flags
                if let text = stroke.text {
                    // A key types one character; 20 UTF-16 units is the per-event limit.
                    let units = Array(text.utf16.prefix(20))
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                }
                let last = index == strokes.count - 1 && !down && part != .erase
                event.setIntegerValueField(.eventSourceUserData,
                                           value: SyntheticMark.own(seq: retype.seq, last: last).userData)
                events.append(event)
            }
        }
        return events
    }

    public static func post(_ retype: Retype, part: Part = .all) {
        let source = CGEventSource(stateID: .privateState)
        for event in events(for: retype, source: source, part: part) {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Types `text` as it is, character by character, with no key of its own:
    /// puts back the end of a word a retype erased and could not replace.
    /// Marked as the retype's, none of them the last.
    public static func type(_ text: String, seq: UInt32) {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let units = Array(String(character).utf16.prefix(20))
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData,
                                           value: SyntheticMark.own(seq: seq, last: false).userData)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
