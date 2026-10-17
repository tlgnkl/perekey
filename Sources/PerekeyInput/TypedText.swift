// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import PerekeyCore

/// Dictated text as key events, for `PasteStrategy.keystrokes`: a terminal
/// wraps a paste in bracketed-paste markers, and an app inside it may fold a
/// long paste into "[Pasted text #1]". Typed text shows as it is.
///
/// One character per key event. Native terminals take 20 UTF-16 units in one
/// event, but xterm.js (Orca, VS Code, Hyper, Tabby) reads text of more than
/// one unit from its text area on a timer, and the strokes after it come out
/// ahead. A single unit goes through at once. Measured with 1600 characters
/// at this pace: Terminal and xterm.js in Chromium show them all in about
/// 0.35 s; both drop characters when the events come without pauses.
///
/// Flags are empty, never ⌥⌘⌃. Every event is marked `SyntheticMark.typed`:
/// Perekey's tap lets it through and the autoswitch does not see it. Every
/// `ackEvery` strokes, and on the last one, the key up is a checkpoint the
/// typing waits for (`TextPaster`), so no more than that many strokes are on
/// their way. Posted to `.cghidEventTap`, as `TextSink`.
public enum TypedText {
    /// UTF-16 units one key event carries at most (`CGEventKeyboardSetUnicodeString`).
    public static let unitLimit = 20
    /// The key code of every event: a letter, which no terminal or shell
    /// maps to an action by itself. Apps read the text the event carries.
    /// Claude Code asks kitty and Ghostty for `CSI > 5 u` (flags 1 and 4),
    /// which sends plain keys as text; an app asking for flag 8 without 16
    /// would get "a" for every stroke.
    public static let keyCode: UInt16 = 0 // kVK_ANSI_A
    /// Strokes posted back to back before a `pause`.
    public static let burst = 16
    public static let pause: Duration = .milliseconds(2)
    /// After a stroke of more than one unit (an emoji, a letter with a
    /// combining mark), for xterm.js to read it before the next one.
    public static let slowPause: Duration = .milliseconds(50)
    /// Strokes between checkpoints: four bursts.
    public static let ackEvery = 4 * burst

    /// The strokes of `text`, one character each, composed first (NFC): "é"
    /// as e and a combining mark would be a slow stroke. A character of more
    /// than `limit` units (a long run of combining marks) is split between
    /// its scalars, so no surrogate pair is broken.
    public static func strokes(_ text: String, limit: Int = unitLimit) -> [String] {
        var strokes: [String] = []
        for character in text.precomposedStringWithCanonicalMapping {
            let stroke = String(character)
            guard stroke.utf16.count > limit else {
                strokes.append(stroke)
                continue
            }
            var part = ""
            for scalar in stroke.unicodeScalars {
                if part.utf16.count + scalar.utf16.count > limit {
                    strokes.append(part)
                    part = ""
                }
                part.unicodeScalars.append(scalar)
            }
            if !part.isEmpty { strokes.append(part) }
        }
        return strokes
    }

    /// How long to wait after `stroke`, the `count`-th since the last pause;
    /// nil to post the next one at once.
    static func pause(after stroke: String, count: Int) -> Duration? {
        if stroke.utf16.count > 1 { return slowPause }
        return count >= burst ? pause : nil
    }

    /// Key down and key up carrying `stroke`; the key up has `mark`, the key
    /// down the same without `ack`.
    public static func events(for stroke: String, source: CGEventSource?, mark: SyntheticMark) -> [CGEvent] {
        let units = Array(stroke.utf16.prefix(unitLimit))
        return [true, false].compactMap { down in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return nil }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            var own = mark
            if down, case let .typed(seq, _) = mark { own = .typed(seq: seq, ack: false) }
            event.setIntegerValueField(.eventSourceUserData, value: own.userData)
            return event
        }
    }

    /// - Parameter source: one for all strokes of a text, `.privateState`.
    public static func post(_ stroke: String, source: CGEventSource?, mark: SyntheticMark) {
        for event in events(for: stroke, source: source, mark: mark) {
            event.post(tap: .cghidEventTap)
        }
    }
}
