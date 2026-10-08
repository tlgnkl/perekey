// SPDX-License-Identifier: GPL-3.0-or-later
//
// Posts keystrokes that look like a person typing, for scripts/e2e.sh.
//
// The events carry no Perekey mark (no eventSourceUserData) and come from the
// HID system state, so Perekey's tap treats them as user input.
//
//   perekey-e2e check                 exit 0 if this process may post events
//   perekey-e2e layout                print the current keyboard layout id
//   perekey-e2e type [--delay-ms N] TEXT   type TEXT using ABC key codes
//   perekey-e2e key NAME...           return, tab, delete, space, cmd-a, cmd-c, ctrl-d
//   perekey-e2e option | shift        tap the modifier (flagsChanged down, up)
//   perekey-e2e sleep-ms N            pause

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Key codes of the ABC (US) layout: character -> (keyCode, needs Shift).
let abc: [Character: (UInt16, Bool)] = {
    var map: [Character: (UInt16, Bool)] = [:]
    let letters: [(Character, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
        ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
        ("j", 38), ("k", 40), ("n", 45), ("m", 46),
    ]
    for (ch, code) in letters {
        map[ch] = (code, false)
        map[Character(ch.uppercased())] = (code, true)
    }
    let digits: [(Character, UInt16)] = [
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26),
        ("8", 28), ("9", 25), ("0", 29),
    ]
    for (ch, code) in digits { map[ch] = (code, false) }
    let punctuation: [(Character, UInt16)] = [
        (",", 43), (".", 47), (";", 41), ("'", 39), ("[", 33), ("]", 30), ("-", 27),
        ("=", 24), ("/", 44), ("`", 50), ("\\", 42),
    ]
    for (ch, code) in punctuation { map[ch] = (code, false) }
    map[" "] = (49, false)
    return map
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("perekey-e2e: \(message)\n".utf8))
    exit(2)
}

func pause(ms: Int) {
    if ms > 0 { usleep(UInt32(ms) * 1000) }
}

func post(_ event: CGEvent?) {
    guard let event else { fail("cannot create event") }
    event.post(tap: .cghidEventTap)
}

func stroke(_ code: UInt16, flags: CGEventFlags = [], holdMs: Int = 8) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
        if down { pause(ms: holdMs) }
    }
}

/// A bare modifier press: flagsChanged with the flag set, then cleared.
func tapModifier(code: UInt16, flag: CGEventFlags, holdMs: Int = 40) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = down ? flag : []
        post(event)
        if down { pause(ms: holdMs) }
    }
}

func typeText(_ text: String, delayMs: Int) {
    for ch in text {
        guard let (code, shift) = abc[ch] else { fail("no ABC key for \"\(ch)\"") }
        if shift {
            // Shift down, key, Shift up: what a person does.
            tapShiftAround { stroke(code, flags: .maskShift) }
        } else {
            stroke(code)
        }
        pause(ms: delayMs)
    }
}

func tapShiftAround(_ body: () -> Void) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true)
        event?.type = .flagsChanged
        event?.flags = down ? .maskShift : []
        post(event)
        if down { body() }
    }
}

func namedKey(_ name: String) {
    switch name {
    case "return": stroke(36)
    case "tab": stroke(48)
    case "delete": stroke(51)
    case "space": stroke(49)
    case "cmd-a": stroke(0, flags: .maskCommand)
    case "cmd-c": stroke(8, flags: .maskCommand)
    case "ctrl-d": stroke(2, flags: .maskControl)
    default: fail("unknown key \(name)")
    }
}

func currentLayoutID() -> String {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return "unknown" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { fail("usage: perekey-e2e check|layout|type|key|option|shift|sleep-ms") }
let command = args.removeFirst()

switch command {
case "check":
    exit(CGPreflightPostEventAccess() ? 0 : 1)
case "layout":
    print(currentLayoutID())
case "type":
    var delay = 12
    if args.first == "--delay-ms", args.count >= 2 {
        delay = Int(args[1]) ?? delay
        args.removeFirst(2)
    }
    guard let text = args.first else { fail("type needs TEXT") }
    typeText(text, delayMs: delay)
case "key":
    for name in args { namedKey(name); pause(ms: 20) }
case "option":
    tapModifier(code: 58, flag: .maskAlternate)
case "shift":
    tapModifier(code: 56, flag: .maskShift)
case "sleep-ms":
    pause(ms: Int(args.first ?? "") ?? 0)
default:
    fail("unknown command \(command)")
}
