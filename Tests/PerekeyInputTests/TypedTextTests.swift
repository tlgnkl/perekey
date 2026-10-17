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
        // é composes; the circumflex has nothing to compose with and stays a mark.
        let combining = "e\u{301}\u{302}"
        #expect(TypedText.strokes("a😀\(family)\(flag)\(combining)b") == ["a", "😀", family, flag, "\u{E9}\u{302}", "b"])
    }

    @Test func decomposedTextIsComposedFirst() {
        // NFD from a file or a model: one unit a stroke, no slow pauses.
        let strokes = TypedText.strokes("cafe\u{301} и\u{306}")
        #expect(strokes == ["c", "a", "f", "\u{E9}", " ", "\u{439}"])
        #expect(strokes.allSatisfy { TypedText.pause(after: $0, count: 1) == nil })
    }

    @Test func aCharacterOverTheLimitIsSplitBetweenItsScalars() {
        // A letter under 30 combining marks: 31 units, one character.
        let zalgo = "q" + String(repeating: "\u{301}", count: 30)
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
        let events = TypedText.events(for: "ж", source: nil, mark: .typed(seq: 3, ack: true))
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
            #expect(mark == .typed(seq: 3, ack: index == 1), "the key up is the checkpoint")
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
        var secureInputOwner: SecureInputOwner?
        var flags: CGEventFlags = []
        var strokes: [String] = []
        var commandV = 0
        var afterPaste = 0
        var pauses: [Duration] = []
        /// What happened, in order: "typing on", "seen 1", "after paste", …
        var log: [String] = []
        /// The tap sees the checkpoints.
        var acknowledges = true
        var tapRunning = true
        weak var paster: TextPaster?
        /// Called after every stroke, with the strokes so far.
        var onStroke: ((Int) -> Void)?
        var task: Task<PasteResult, Never>?
    }

    private func make(_ probe: Probe, pasteboard: CountingPasteboard = CountingPasteboard(),
                      read: (@MainActor (Int) -> PasteTarget?)? = nil,
                      sleep: @escaping @MainActor (Duration) async -> Void = { _ in }) -> TextPaster
    {
        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) { probe.commandV += 1 }
        var reads = 0
        let paster = TextPaster(
            plainPaste: plain,
            readTarget: { _ in
                reads += 1
                return read.map { $0(reads) } ?? probe.current
            },
            frontmostPID: { probe.frontmost },
            secureInputOwner: { probe.secureInputOwner },
            modifierFlags: { probe.flags },
            bundleID: { _ in probe.bundleID },
            postStroke: { stroke, _, mark in
                probe.strokes.append(stroke)
                if case let .typed(seq, ack: true) = mark, probe.acknowledges {
                    probe.log.append("seen \(seq)")
                    probe.paster?.typedSeen(seq: seq)
                }
                probe.onStroke?(probe.strokes.count)
            },
            sleep: { duration in
                probe.pauses.append(duration)
                await sleep(duration)
            },
            tapRunning: { probe.tapRunning },
            typingChanged: { probe.log.append("typing \($0 ? "on" : "off")") },
            afterPaste: {
                probe.afterPaste += 1
                probe.log.append("after paste")
            }
        )
        probe.paster = paster
        return paster
    }

    private static let long = String(repeating: "x", count: 100)

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

    @Test func theTapIsToldAndTheTextGoesOnlyAfterTheLastCheckpoint() async {
        let probe = Probe()
        let paster = make(probe)
        #expect(await paster.paste(Self.long, into: field()) == .pasted)
        // 100 strokes: checkpoints after 64 and on the last one.
        #expect(probe.log == ["typing on", "seen 1", "seen 2", "typing off", "after paste"])
    }

    @Test func noMoreThanACheckpointOfStrokesIsOnItsWay() async {
        let probe = Probe()
        let paster = make(probe)
        var unseenAtMost = 0
        probe.onStroke = { count in
            let seen = probe.log.filter { $0.hasPrefix("seen") }.count
            unseenAtMost = max(unseenAtMost, count - seen * TypedText.ackEvery)
        }
        #expect(await paster.paste(String(repeating: "x", count: 300), into: field()) == .pasted)
        #expect(unseenAtMost <= TypedText.ackEvery)
    }

    @Test func aTapThatDoesNotSeeTheCheckpointsIsWaitedForOnce() async {
        let probe = Probe()
        probe.acknowledges = false
        let paster = make(probe)
        #expect(await paster.paste(String(repeating: "x", count: 300), into: field()) == .pasted)
        #expect(probe.strokes.count == 300)
        #expect(probe.pauses.filter { $0 == TextPaster.seenTimeout }.count == 1, "no more waiting after the first")
    }

    /// A paster whose checkpoints never come back, and whose wait for one
    /// lasts a minute unless `whileWaiting`, run as the wait begins, ends it.
    private func waiting(_ probe: Probe, whileWaiting: @escaping @MainActor (TextPaster) -> Void) -> TextPaster {
        probe.acknowledges = false
        var paster: TextPaster!
        paster = make(probe, sleep: { duration in
            guard duration == TextPaster.seenTimeout else { return }
            Task { whileWaiting(paster) }
            try? await Task.sleep(for: .seconds(60))
        })
        return paster
    }

    @Test func cancellingTheTaskEndsTheWaitForACheckpoint() async {
        let probe = Probe()
        let paster = waiting(probe) { _ in probe.task?.cancel() }
        let task = Task { await paster.paste(Self.long, into: field()) }
        probe.task = task
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await task.value == .failed(.interrupted))
        #expect(clock.now - start < .seconds(10), "not the minute of the wait")
        #expect(probe.strokes.count == TypedText.ackEvery)
        #expect(probe.afterPaste == 1)
    }

    @Test func aKeyOfTheUsersEndsTheWaitForACheckpoint() async {
        let probe = Probe()
        let paster = waiting(probe) { $0.typingInterrupted() }
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == TypedText.ackEvery)
    }

    @Test func withoutPerekeysTapATerminalGetsThePaste() async {
        // Suspended or without access: typing would see neither the
        // user's keys nor its checkpoints.
        let probe = Probe()
        probe.tapRunning = false
        let paster = make(probe)
        #expect(paster.strategy(for: "text", pid: 100) == .commandV)
        #expect(await paster.paste("text", into: field()) == .pasted)
        #expect(probe.strokes.isEmpty)
        #expect(probe.commandV == 1)
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
        #expect(probe.log.isEmpty, "the tap is not told")
    }

    @Test func anotherAppInFrontStopsTheTyping() async {
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 20 { probe.frontmost = 200 } }
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == 2 * TypedText.burst, "stops at the next pause")
        #expect(probe.afterPaste == 1, "the tap must leave the typed part alone")
        #expect(probe.log == ["typing on", "typing off", "after paste"], "the tap judges again, then forgets")
    }

    @Test func cancellingTheTaskStopsTheTypingAtOnce() async {
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 20 { probe.task?.cancel() } }
        let task = Task { await paster.paste(Self.long, into: field()) }
        probe.task = task
        #expect(await task.value == .failed(.interrupted))
        #expect(probe.strokes.count == 20, "the rest is not typed")
        #expect(probe.afterPaste == 1)
    }

    @Test func aKeyOfTheUsersStopsTheTypingAtOnce() async {
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 20 { paster.typingInterrupted() } }
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == 20)
        #expect(probe.afterPaste == 1)
        // The next typing is not stopped by it.
        probe.onStroke = nil
        probe.strokes = []
        #expect(await paster.paste(Self.long, into: field()) == .pasted)
        #expect(probe.strokes.count == 100)
    }

    @Test func secureInputMidTypingStopsItAsSecureInputWhileTyping() async {
        let probe = Probe()
        let paster = make(probe)
        let owner = SecureInputOwner.process(pid: 300, name: "Terminal", bundleID: "com.apple.Terminal")
        probe.onStroke = { if $0 == 20 { probe.secureInputOwner = owner } }
        #expect(await paster.paste(Self.long, into: field()) == .secureInputWhileTyping(owner: owner),
                "not .secureInput, which offers the whole text again")
        #expect(probe.strokes.count == 2 * TypedText.burst)
        #expect(probe.afterPaste == 1)
    }

    @Test func aModifierDownMidTypingStopsIt() async {
        // ⌘ and the next stroke on the A key would be ⌘A.
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 20 { probe.flags = .maskCommand } }
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == 2 * TypedText.burst)
        #expect(probe.afterPaste == 1)
    }

    @Test func theFocusIsCheckedOnceMoreAfterTheLastStrokeWasSeen() async {
        let probe = Probe()
        let paster = make(probe)
        probe.onStroke = { if $0 == 100 { probe.frontmost = 200 } }
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == 100)
        #expect(probe.log == ["typing on", "seen 1", "seen 2", "typing off", "after paste"])
    }

    @Test func anotherFieldStopsTheTyping() async {
        let probe = Probe()
        // Every pause outlasts the AX check interval; the first read is the check before typing.
        let paster = make(probe, read: { $0 == 1 ? field() : field(element: 3) },
                          sleep: { _ in try? await Task.sleep(for: TextPaster.typingCheck) })
        #expect(await paster.paste(Self.long, into: field()) == .failed(.interrupted))
        #expect(probe.strokes.count == TypedText.burst)
        #expect(probe.afterPaste == 1)
    }

    @Test func aFocusThatDoesNotAnswerDoesNotStopTheTyping() async {
        // An app busy with the keys may not answer AX meanwhile.
        let probe = Probe()
        var reads = 0
        let paster = make(probe, read: {
            reads = $0
            return $0 == 1 ? field() : nil
        }, sleep: { _ in try? await Task.sleep(for: TextPaster.typingCheck) })
        #expect(await paster.paste(Self.long, into: field()) == .pasted)
        #expect(probe.strokes.count == 100)
        #expect(reads > 1, "the focus was read while typing")
    }
}
