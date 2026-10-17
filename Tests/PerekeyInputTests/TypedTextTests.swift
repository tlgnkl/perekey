// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import PerekeyCore
import Testing
@testable import PerekeyInput

@Suite struct TypedTextTests {
    @Test func oneCharacterPerStroke() {
        #expect(TypedText.strokes("при вет") == ["п", "р", "и", " ", "в", "е", "т"])
        #expect(TypedText.strokes("") == [])
    }

    @Test func charactersOfMoreThanOneUnitStayWhole() {
        let family = "👨‍👩‍👧‍👦"
        let flag = "🇷🇺"
        let combining = "e\u{301}\u{302}"
        #expect(TypedText.strokes("a😀\(family)\(flag)\(combining)b") == ["a", "😀", family, flag, combining, "b"])
    }

    @Test func aCharacterOverTheLimitIsSplitBetweenItsScalars() {
        // A letter under 30 combining marks: 31 units, one character.
        let zalgo = "z" + String(repeating: "\u{301}", count: 30)
        let strokes = TypedText.strokes(zalgo)
        #expect(strokes.count == 2)
        #expect(strokes.joined() == zalgo)
        #expect(strokes.allSatisfy { $0.utf16.count <= TypedText.unitLimit })
        // A ZWJ run of emoji over the limit: no surrogate pair is broken.
        let crowd = Array(repeating: "😀", count: 15).joined(separator: "\u{200D}")
        let parts = TypedText.strokes(crowd)
        #expect(parts.joined() == crowd)
        #expect(parts.allSatisfy { $0.utf16.count <= TypedText.unitLimit })
        #expect(parts.allSatisfy { String($0.utf16) != nil }, "every part is valid UTF-16")
    }

    @Test func pausesAfterABurstAndLongerAfterAWideCharacter() {
        #expect(TypedText.pause(after: "a", count: 1) == nil)
        #expect(TypedText.pause(after: "a", count: TypedText.burst) == TypedText.pause)
        #expect(TypedText.pause(after: "😀", count: 1) == TypedText.slowPause)
    }

    @Test func eventsCarryTheTextMarkedAsOwn() throws {
        let events = TypedText.events(for: "ж", source: nil)
        try #require(events.count == 2)
        #expect(events.map { $0.type } == [.keyDown, .keyUp])
        for (index, event) in events.enumerated() {
            #expect(event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty)
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            #expect(![KeyCode.return, KeyCode.tab, KeyCode.escape, KeyCode.keypadEnter, KeyCode.delete].contains(keyCode))
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
            #expect(String(utf16CodeUnits: units, count: length) == "ж")
            let mark = SyntheticMark(userData: event.getIntegerValueField(.eventSourceUserData))
            #expect(mark == .own(seq: 0, last: index == 1), "seq 0 is never a fence's")
            #expect(EventOrigin(mark: mark).isOwn, "the tap lets it through without autoswitching")
        }
    }
}

/// A pasteboard that only counts what touches it: typing must not.
@MainActor
private final class CountingPasteboard: PasteboardStore {
    var changeCount = 0
    var writes = 0
    var plainString: String? { "mine" }
    func snapshot() -> PlainPaste.Snapshot { PlainPaste.Snapshot(items: []) }
    func writePlain(_: String) -> Int {
        writes += 1
        changeCount += 1
        return changeCount
    }

    func restore(_: PlainPaste.Snapshot) -> Int {
        writes += 1
        changeCount += 1
        return changeCount
    }
}

private func element(_ pid: pid_t) -> AXElementRef { AXElementRef(AXUIElementCreateApplication(pid)) }

private func field(pid: pid_t = 100, element id: pid_t = 2) -> PasteTarget {
    PasteTarget(pid: pid, window: element(1),
                element: PasteTarget.Element(ref: element(id), role: "AXTextArea", subrole: nil, identifier: nil))
}

@MainActor
@Suite struct TypingPasteTests {
    final class Probe {
        var bundleID: String? = "com.apple.Terminal"
        var current: PasteTarget? = field()
        var frontmost: pid_t? = 100
        var strokes: [String] = []
        var commandV = 0
        var afterPaste = 0
        var pauses: [Duration] = []
        /// Called after every stroke, with the strokes so far.
        var onStroke: ((Int) -> Void)?
    }

    private func make(_ probe: Probe, pasteboard: CountingPasteboard = CountingPasteboard()) -> TextPaster {
        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) { probe.commandV += 1 }
        return TextPaster(
            plainPaste: plain,
            readTarget: { _ in probe.current },
            frontmostPID: { probe.frontmost },
            modifierFlags: { [] },
            bundleID: { _ in probe.bundleID },
            postStroke: { stroke, _ in
                probe.strokes.append(stroke)
                probe.onStroke?(probe.strokes.count)
            },
            sleep: { probe.pauses.append($0) },
            afterPaste: { probe.afterPaste += 1 }
        )
    }

    @Test func aTerminalGetsTheTextTypedAndThePasteboardStaysAlone() async {
        let probe = Probe()
        let pasteboard = CountingPasteboard()
        let paster = make(probe, pasteboard: pasteboard)
        let text = String(repeating: "Привет, мир, и снова привет 😀 ", count: 20)
        #expect(await paster.paste(text, into: field()) == .pasted)
        #expect(probe.strokes.joined() == text)
        #expect(probe.commandV == 0)
        #expect(pasteboard.writes == 0)
        #expect(probe.afterPaste == 1)
        #expect(probe.pauses.contains(TypedText.slowPause))
        #expect(probe.pauses.contains(TypedText.pause))
    }

    @Test func strategyByAppTextAndChoice() {
        let probe = Probe()
        let paster = make(probe)
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.stablyai.orca"] {
            probe.bundleID = id
            #expect(paster.strategy(for: "ls -la", pid: 100) == .keystrokes, "\(id)")
        }
        probe.bundleID = "com.apple.Terminal"
        for broken in ["one\ntwo", "one\rtwo", "one\u{2028}two", "one\u{2029}two", "a\tb", "a\u{1B}[A"] {
            #expect(paster.strategy(for: broken, pid: 100) == .commandV, "\(broken.debugDescription)")
        }
        for editor in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.intellij",
                       "com.apple.TextEdit"]
        {
            probe.bundleID = editor
            #expect(paster.strategy(for: "text", pid: 100) == .commandV, "\(editor)")
        }
        probe.bundleID = nil
        #expect(paster.strategy(for: "text", pid: 100) == .commandV, "an app without a bundle ID")
    }

    @Test func theUsersChoiceOverridesTheTerminalList() {
        let probe = Probe()
        let paster = make(probe)
        paster.insertion = { $0 == "com.microsoft.VSCode" ? .typing : $0 == "com.apple.Terminal" ? .paste : .automatic }
        probe.bundleID = "com.microsoft.VSCode"
        #expect(paster.strategy(for: "text", pid: 100) == .keystrokes)
        #expect(paster.strategy(for: "one\ntwo", pid: 100) == .commandV, "a break would send the line")
        probe.bundleID = "com.apple.Terminal"
        #expect(paster.strategy(for: "text", pid: 100) == .commandV)
        paster.strategy = .menu
        #expect(paster.strategy(for: "text", pid: 100) == .menu, "a fixed strategy wins")
    }

    @Test func aTextWithALineBreakIsPastedIntoATerminal() async {
        let probe = Probe()
        let paster = make(probe)
        #expect(await paster.paste("one\ntwo", into: field()) == .pasted)
        #expect(probe.strokes.isEmpty)
        #expect(probe.commandV == 1)
    }

    @Test func theChecksComeBeforeTheFirstStroke() async {
        let probe = Probe()
        let paster = make(probe)
        probe.current = field(element: 3)
        #expect(await paster.paste("text", into: field()) == .targetChanged)
        probe.current = PasteTarget(pid: 100, window: element(1),
                                    element: PasteTarget.Element(ref: element(2), role: "AXTextField",
                                                                 subrole: kAXSecureTextFieldSubrole, identifier: nil))
        #expect(await paster.paste("text", into: probe.current!) == .secureField)
        #expect(probe.strokes.isEmpty)
        #expect(probe.afterPaste == 0)
    }

    @Test func anotherAppInFrontStopsTheTyping() async {
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 20 { probe.frontmost = 200 } }
        let text = String(repeating: "x", count: 100)
        #expect(await paster.paste(text, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == 2 * TypedText.burst, "stops at the next pause")
        #expect(probe.afterPaste == 1, "the tap must leave the typed part alone")
    }

    /// A paster whose AX reads come from `read` (the first is the check
    /// before typing), and whose every pause outlasts the AX check interval.
    private func typer(_ probe: Probe, read: @escaping @MainActor (Int) -> PasteTarget?) -> TextPaster {
        var reads = 0
        return TextPaster(
            plainPaste: PlainPaste(pasteboard: CountingPasteboard(), restoreDelay: .seconds(60)) {},
            readTarget: { _ in
                reads += 1
                return read(reads)
            },
            frontmostPID: { probe.frontmost },
            modifierFlags: { [] },
            bundleID: { _ in probe.bundleID },
            postStroke: { stroke, _ in probe.strokes.append(stroke) },
            sleep: { _ in try? await Task.sleep(for: TextPaster.typingCheck) },
            afterPaste: { probe.afterPaste += 1 }
        )
    }

    @Test func anotherFieldStopsTheTyping() async {
        let probe = Probe()
        let paster = typer(probe) { $0 == 1 ? field() : field(element: 3) }
        #expect(await paster.paste(String(repeating: "x", count: 100), into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == TypedText.burst)
        #expect(probe.afterPaste == 1)
    }

    @Test func aFocusThatDoesNotAnswerDoesNotStopTheTyping() async {
        // An app busy with the keys may not answer AX meanwhile.
        let probe = Probe()
        var reads = 0
        let paster = typer(probe) {
            reads = $0
            return $0 == 1 ? field() : nil
        }
        #expect(await paster.paste(String(repeating: "x", count: 100), into: field()) == .pasted)
        #expect(probe.strokes.count == 100)
        #expect(reads > 1, "the focus was read while typing")
    }
}
