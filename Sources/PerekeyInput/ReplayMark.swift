// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import PerekeyCore

/// Marks held events for posting again.
///
/// An event that already carries a non-zero `eventSourceUserData` (it came
/// from a program with a mark of its own) keeps it: setting the field changes
/// nothing, on the event or on a copy. Such an event would come back
/// unmarked, the replay gate would not count it, and the keys behind it would
/// wait out the timeout. Then the event is built again from its content, from
/// a source of ours.
public enum ReplayMark {
    /// The event to post: `event` itself when the mark took, else a rebuilt copy.
    /// Falls back to `event` if it cannot be rebuilt.
    /// `layouts`: the enabled layouts, to tell a string the program set from one the system computed.
    public static func marked(_ event: CGEvent, layouts: [LayoutMap] = []) -> CGEvent {
        let mark = SyntheticMark.replayed.userData
        event.setIntegerValueField(.eventSourceUserData, value: mark)
        if event.getIntegerValueField(.eventSourceUserData) == mark { return event }
        return rebuilt(event, mark: mark, layouts: layouts) ?? event
    }

    /// The unicode string of the original goes to the copy only when a program
    /// set it. A string the system computed from the key code belongs to the
    /// layout at the time of creation (ABC: "b" for key 11); Perekey may
    /// replay the key after switching to Russian, and an explicit "b" would
    /// then type "b" instead of "и". So the rule: the string is computed when
    /// some enabled layout types exactly it for this key code and these
    /// modifiers (the same `UCKeyTranslate` tables as `LayoutReader`); then
    /// the copy has none, and the system fills it in for the current layout.
    /// Any other string (key 0 with "жё", a key without a character) was set
    /// explicitly and is carried over. With no layouts known, it is carried over.
    /// The source is `.privateState`, as everywhere else in Perekey's posts: its
    /// own key state does not add modifiers held at that moment, so `flags` is
    /// copied from the original and is all the copy carries.
    static func rebuilt(_ event: CGEvent, mark: Int64, layouts: [LayoutMap]) -> CGEvent? {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = mark
        let copy: CGEvent?
        switch event.type {
        case .keyDown, .keyUp:
            let code = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            copy = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: event.type == .keyDown)
        case .flagsChanged:
            copy = CGEvent(source: source)
            copy?.type = .flagsChanged
            copy?.setIntegerValueField(.keyboardEventKeycode, value: event.getIntegerValueField(.keyboardEventKeycode))
        default:
            return nil
        }
        guard let copy else { return nil }
        copy.flags = event.flags
        copy.timestamp = event.timestamp
        for field in [CGEventField.keyboardEventAutorepeat, .keyboardEventKeyboardType] {
            copy.setIntegerValueField(field, value: event.getIntegerValueField(field))
        }
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        if length > 0 {
            var units = [UniChar](repeating: 0, count: length)
            event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &units)
            let text = String(utf16CodeUnits: units, count: length)
            let stroke = KeyStroke(CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                                   LayoutModifiers(eventFlags: event.flags.rawValue))
            let computed = layouts.contains { $0.text(for: stroke) == text }
            if !computed { copy.keyboardSetUnicodeString(stringLength: length, unicodeString: units) }
        }
        copy.setIntegerValueField(.eventSourceUserData, value: mark)
        return copy.getIntegerValueField(.eventSourceUserData) == mark ? copy : nil
    }
}
