// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Testing
@testable import PerekeyInput

/// A pasteboard in memory that counts writes; `copyByUser` is someone else's write.
@MainActor
private final class FakePasteboard: PasteboardStore {
    var changeCount = 0
    var contents = PlainPaste.Snapshot(items: [[.init(type: "public.utf8-plain-text", data: Data("mine".utf8))]])
    var writes = 0

    var plainString: String? {
        contents.items.first?.first { $0.type == NSPasteboard.PasteboardType.string.rawValue }
            .map { String(decoding: $0.data, as: UTF8.self) }
    }

    func snapshot() -> PlainPaste.Snapshot { contents }

    func writePlain(_ text: String) -> Int {
        writes += 1
        contents = PlainPaste.Snapshot(items: [[
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)),
            .init(type: PlainPaste.transientType.rawValue, data: Data()),
        ]])
        changeCount += 1
        return changeCount
    }

    func restore(_ snapshot: PlainPaste.Snapshot) -> Int {
        writes += 1
        contents = snapshot
        changeCount += 1
        return changeCount
    }

    func copyByUser(_ text: String) {
        contents = PlainPaste.Snapshot(items: [[.init(type: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(text.utf8))]])
        changeCount += 1
    }
}

private func ref(_ pid: pid_t) -> AXElementRef { AXElementRef(AXUIElementCreateApplication(pid)) }

private func target(pid: pid_t = 100, window: pid_t? = 1, element: pid_t? = 2, role: String? = "AXTextArea",
                    subrole: String? = nil, identifier: String? = nil, web: String? = nil) -> PasteTarget
{
    PasteTarget(pid: pid, window: window.map(ref),
                element: element.map { PasteTarget.Element(ref: ref($0), role: role, subrole: subrole,
                                                           identifier: identifier, webDocument: web) })
}

@MainActor
@Suite struct PasteTargetTests {
    @Test func sameTargetIsSame() {
        #expect(target().isSame(as: target()))
    }

    @Test func anotherAppOrWindowIsAChange() {
        #expect(!target().isSame(as: target(pid: 101)))
        #expect(!target().isSame(as: target(window: 9)))
        #expect(!target().isSame(as: target(window: nil)), "a window the app no longer reports")
    }

    @Test func anotherElementOfTheSameKindOutsideTheWebIsAChange() {
        // Terminal tabs: text areas without identifiers in one window.
        #expect(!target(element: 2).isSame(as: target(element: 3)))
        #expect(!target(element: 2, identifier: "q").isSame(as: target(element: 3, identifier: "q")))
    }

    @Test func aRebuiltWebElementOnTheSamePageIsTheSameTarget() {
        // Chromium and Electron hand out a new AX object for the same field.
        let page = "https://example.com/compose"
        #expect(target(element: 2, web: page).isSame(as: target(element: 3, web: page)))
        #expect(target(element: 2, identifier: "q", web: page)
            .isSame(as: target(element: 3, identifier: "q", web: page)))
    }

    @Test func aWebElementOfAnotherPageOrKindIsAChange() {
        let page = "https://example.com/compose"
        // Another tab of the same window.
        #expect(!target(element: 2, web: page).isSame(as: target(element: 3, web: "https://prod.example.com/")))
        #expect(!target(element: 2, web: page).isSame(as: target(element: 3, web: nil)))
        #expect(!target(element: 2, web: nil).isSame(as: target(element: 3, web: nil)))
        #expect(!target(element: 2, role: "AXTextArea", web: page)
            .isSame(as: target(element: 3, role: "AXTextField", web: page)))
        #expect(!target(element: 2, identifier: "q", web: page)
            .isSame(as: target(element: 3, identifier: "search", web: page)))
    }

    @Test func anIdentifierOnOneSideOnlyIsAChange() {
        let page = "https://example.com/compose"
        #expect(!target(element: 2, identifier: "q", web: page).isSame(as: target(element: 3, web: page)))
        #expect(!target(element: 2, web: page).isSame(as: target(element: 3, identifier: "q", web: page)))
    }

    @Test func anotherKindOfElementIsAChange() {
        #expect(!target().isSame(as: target(element: 3, role: "AXTextField", subrole: kAXSecureTextFieldSubrole)))
    }

    @Test func appTargetComparesTheProcessOnly() {
        #expect(PasteTarget.app(pid: 100).isSame(as: target()))
        #expect(!PasteTarget.app(pid: 100).isSame(as: target(pid: 101)))
        #expect(!target().isSame(as: .app(pid: 100)), "the window is gone from the answer")
    }

    @Test func aMissingElementIsNotCompared() {
        #expect(target(element: nil).isSame(as: target()))
        #expect(target().isSame(as: target(element: nil)))
    }

    @Test func targetWithoutWindowComparesTheApp() {
        #expect(target(window: nil).isSame(as: target(window: 9)))
        #expect(!target(window: nil).isSame(as: target(pid: 7, window: 9)))
    }

    @Test func passwordFieldIsSecure() {
        #expect(target(role: "AXTextField", subrole: kAXSecureTextFieldSubrole).isSecureField)
        #expect(!target().isSecureField)
    }
}

@MainActor
@Suite struct TextPasterTests {
    private final class Probe {
        var posts = 0
        var menuPresses = 0
        var afterPaste = 0
        var current: PasteTarget? = target()
        var frontmost: pid_t? = 100
        var secureInputOwner: SecureInputOwner?
        var menuWorks = true
        var flags: [CGEventFlags] = []
    }

    private func make(_ probe: Probe, pasteboard: FakePasteboard,
                      modifierTimeout: Duration = .milliseconds(200)) -> (TextPaster, PlainPaste)
    {
        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) { probe.posts += 1 }
        let paster = TextPaster(
            plainPaste: plain,
            readTarget: { _ in probe.current },
            frontmostPID: { probe.frontmost },
            pressPasteMenuItem: { _ in probe.menuPresses += 1; return probe.menuWorks },
            secureInputOwner: { probe.secureInputOwner },
            modifierFlags: { probe.flags.isEmpty ? [] : probe.flags.removeFirst() },
            modifierTimeout: modifierTimeout,
            afterPaste: { probe.afterPaste += 1 }
        )
        return (paster, plain)
    }

    @Test func pastesTheTextAndPutsThePasteboardBack() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let before = pasteboard.snapshot()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("привет", into: target()) == .pasted)
        #expect(probe.posts == 1)
        #expect(probe.afterPaste == 1)
        #expect(pasteboard.plainString == "привет")
        #expect(pasteboard.contents.items[0].contains { $0.type == PlainPaste.transientType.rawValue })
        plain.restoreNow()
        #expect(pasteboard.snapshot() == before)
    }

    @Test func restoreAfterTheDelayEvenWhenThePostDidNothing() async throws {
        // A ⌘V that never arrived leaves the text on the pasteboard only until the restore.
        let pasteboard = FakePasteboard()
        let before = pasteboard.snapshot()
        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .milliseconds(30)) {}
        #expect(plain.paste(text: "text"))
        for _ in 0..<100 where plain.isRestorePending { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!plain.isRestorePending)
        #expect(pasteboard.snapshot() == before)
    }

    @Test func aPasteboardThatIsNotOursAnyMoreIsNotRestored() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("text", into: target()) == .pasted)
        pasteboard.copyByUser("newer")
        let writes = pasteboard.writes
        plain.restoreNow()
        #expect(pasteboard.plainString == "newer")
        #expect(pasteboard.writes == writes)
    }

    @Test func dictationKeepsTheSnapshotOfAPendingPlainPaste() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let before = pasteboard.snapshot()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        #expect(plain.paste())
        #expect(await paster.paste("dictated", into: target()) == .pasted)
        plain.restoreNow()
        #expect(pasteboard.snapshot() == before)
    }

    @Test func aCopyBetweenTwoDictationsIsWhatComesBack() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("first", into: target()) == .pasted)
        pasteboard.copyByUser("copied in between")
        #expect(await paster.paste("second", into: target()) == .pasted)
        plain.restoreNow()
        #expect(pasteboard.plainString == "copied in between")
        // And after a finished restore as well.
        #expect(await paster.paste("third", into: target()) == .pasted)
        plain.restoreNow()
        pasteboard.copyByUser("copied later")
        #expect(await paster.paste("fourth", into: target()) == .pasted)
        plain.restoreNow()
        #expect(pasteboard.plainString == "copied later")
    }

    @Test func aPasswordOnThePasteboardIsNotPutBack() async {
        // 1Password clears its copy only if the change count did not move.
        let probe = Probe()
        let pasteboard = FakePasteboard()
        pasteboard.contents = PlainPaste.Snapshot(items: [[
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("hunter2".utf8)),
            .init(type: PlainPaste.concealedType.rawValue, data: Data()),
        ]])
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("text", into: target()) == .pasted)
        plain.restoreNow()
        #expect(pasteboard.contents.items.isEmpty)
        #expect(pasteboard.plainString == nil)
    }

    @Test func aChangedTargetLeavesThePasteboardAlone() async {
        let probe = Probe()
        probe.current = target(pid: 200)
        let pasteboard = FakePasteboard()
        let (paster, _) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("text", into: target()) == .targetChanged)
        probe.current = nil
        #expect(await paster.paste("text", into: target()) == .targetChanged, "no answer is no proof")
        probe.frontmost = nil
        #expect(await paster.paste("text", into: target()) == .targetChanged)
        #expect(pasteboard.writes == 0)
        #expect(probe.posts == 0)
        #expect(probe.afterPaste == 0)
    }

    @Test func passwordFieldOrSecureInputLeavesThePasteboardAlone() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let (paster, _) = make(probe, pasteboard: pasteboard)
        let password = target(role: "AXTextField", subrole: kAXSecureTextFieldSubrole)
        probe.current = password
        #expect(await paster.paste("text", into: password) == .secureField)
        // Secure Input held by a process in the background is not a password field.
        probe.current = target()
        let terminal = SecureInputOwner.process(pid: 300, name: "Terminal", bundleID: "com.apple.Terminal")
        probe.secureInputOwner = terminal
        #expect(await paster.paste("text", into: target()) == .secureInput(owner: terminal))
        probe.current = password
        #expect(await paster.paste("text", into: password) == .secureField, "the field wins: no history")
        #expect(pasteboard.writes == 0)
        #expect(probe.posts == 0)
    }

    @Test func withoutAnAXAnswerTheTargetIsTheFrontmostApp() async {
        let probe = Probe()
        probe.current = nil
        let pasteboard = FakePasteboard()
        let (paster, _) = make(probe, pasteboard: pasteboard)
        let captured = await paster.captureTarget()
        #expect(captured == .app(pid: 100))
        // The user switched apps before the end of the dictation.
        probe.frontmost = 200
        #expect(await paster.paste("text", into: .app(pid: 100)) == .targetChanged)
        #expect(pasteboard.writes == 0)
        probe.frontmost = 100
        #expect(await paster.paste("text", into: .app(pid: 100)) == .pasted)
        probe.frontmost = nil
        #expect(await paster.captureTarget() == nil)
    }

    @Test func waitsForTheModifiersToBeReleased() async {
        let probe = Probe()
        probe.flags = [[.maskAlternate, .maskCommand], [.maskAlternate], [.maskAlphaShift]]
        let pasteboard = FakePasteboard()
        // A loaded machine sleeps long between polls.
        let (paster, _) = make(probe, pasteboard: pasteboard, modifierTimeout: .seconds(30))
        #expect(await paster.paste("text", into: target()) == .pasted)
        #expect(probe.flags.isEmpty, "read until only Caps Lock was left")
    }

    @Test func aModifierHeldPastTheTimeoutStopsThePaste() async {
        let probe = Probe()
        probe.flags = Array(repeating: [.maskAlternate], count: 10000)
        let pasteboard = FakePasteboard()
        let (paster, _) = make(probe, pasteboard: pasteboard, modifierTimeout: .milliseconds(50))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await paster.paste("text", into: target()) == .failed(.modifiersHeld))
        #expect(clock.now - start < .seconds(2))
        #expect(pasteboard.writes == 0)
    }

    @Test func emptyTextOrNoAccessTouchesNothing() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let (paster, _) = make(probe, pasteboard: pasteboard)
        #expect(await paster.paste("", into: target()) == .failed(.emptyText))
        let untrusted = TextPaster(plainPaste: PlainPaste(pasteboard: pasteboard) {}, readTarget: { _ in target() },
                                   isTrusted: { false }, modifierFlags: { [] },
                                   afterPaste: {})
        #expect(await untrusted.paste("text", into: target()) == .failed(.noAccess))
        #expect(pasteboard.writes == 0)
    }

    @Test func accessibilityStrategySkipsThePasteboard() async {
        final class Field {
            var set: [String] = []
            var succeeds = true
        }
        let pasteboard = FakePasteboard()
        let field = Field()
        let paster = TextPaster(plainPaste: PlainPaste(pasteboard: pasteboard) {}, readTarget: { _ in target() },
                                setSelectedText: { text, _ in field.set.append(text); return field.succeeds },
                                modifierFlags: { [] }, afterPaste: {})
        paster.strategy = .accessibility
        #expect(await paster.paste("text", into: target()) == .pasted)
        field.succeeds = false
        #expect(await paster.paste("again", into: target()) == .failed(.strategyFailed))
        #expect(field.set == ["text", "again"])
        #expect(pasteboard.writes == 0)
    }

    @Test func menuStrategyPressesTheMenuInsteadOfCommandV() async {
        let probe = Probe()
        let pasteboard = FakePasteboard()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        paster.strategy = .menu
        #expect(await paster.paste("text", into: target()) == .pasted)
        #expect(probe.posts == 0)
        #expect(probe.menuPresses == 1)
        #expect(pasteboard.plainString == "text")
        #expect(plain.isRestorePending)
        plain.restoreNow()
        #expect(pasteboard.plainString == "mine")
    }

    @Test func aMenuPressThatFailsRestoresAtOnce() async {
        let probe = Probe()
        probe.menuWorks = false
        let pasteboard = FakePasteboard()
        let (paster, plain) = make(probe, pasteboard: pasteboard)
        paster.strategy = .menu
        #expect(await paster.paste("text", into: target()) == .failed(.strategyFailed))
        #expect(!plain.isRestorePending)
        #expect(pasteboard.plainString == "mine")
        #expect(probe.afterPaste == 0)
    }
}

@MainActor
@Suite struct DictationSecureInputTests {
    private final class FakeEscape: EscapeHotKey {
        var handler: (@MainActor () -> Void)?
        var registrations = 0
        func register(_ onPress: @escaping @MainActor () -> Void) {
            if handler == nil { registrations += 1 }
            handler = onPress
        }

        func unregister() { handler = nil }
    }

    private final class State {
        var on = false
    }

    private func make(_ state: State, _ escape: FakeEscape) -> (DictationSecureInput, SecureInputMonitor) {
        let monitor = SecureInputMonitor(isOn: { state.on }, ownerPID: { nil }, observe: false)
        return (DictationSecureInput(monitor: monitor, escape: escape, pollInterval: .seconds(60)), monitor)
    }

    @Test func noStartUnderSecureInput() {
        let state = State()
        let (guardian, _) = make(state, FakeEscape())
        #expect(guardian.allowsStart)
        state.on = true
        #expect(!guardian.allowsStart)
    }

    @Test func secureInputDuringASessionStopsItOnce() {
        let state = State()
        let (guardian, monitor) = make(state, FakeEscape())
        var stops = 0
        guardian.onStop = { stops += 1 }
        state.on = true
        monitor.refresh()
        #expect(stops == 0, "no session yet")
        state.on = false
        monitor.refresh()
        guardian.sessionBegan()
        state.on = true
        monitor.refresh()
        state.on = false
        monitor.refresh()
        state.on = true
        monitor.refresh()
        #expect(stops == 1)
        guardian.sessionEnded()
        state.on = false
        monitor.refresh()
        state.on = true
        monitor.refresh()
        #expect(stops == 1, "not after the session")
    }

    @Test func thePollFindsSecureInputWithoutAnyEvent() async throws {
        let state = State()
        let monitor = SecureInputMonitor(isOn: { state.on }, ownerPID: { nil }, observe: false)
        let guardian = DictationSecureInput(monitor: monitor, escape: FakeEscape(), pollInterval: .milliseconds(10))
        var stops = 0
        guardian.onStop = { stops += 1 }
        guardian.sessionBegan()
        state.on = true
        for _ in 0..<200 where stops == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stops == 1)
        guardian.sessionEnded()
    }

    @Test func escapeIsHeldOnlyUnderSecureInputDuringASession() {
        let state = State()
        let escape = FakeEscape()
        let (guardian, monitor) = make(state, escape)
        var cancels = 0
        guardian.onEscape = { cancels += 1 }
        #expect(escape.handler == nil)
        guardian.sessionBegan()
        #expect(escape.handler == nil, "the tap sees Esc while Secure Input is off")
        state.on = true
        monitor.refresh()
        escape.handler?()
        #expect(cancels == 1)
        state.on = false
        monitor.refresh()
        #expect(escape.handler == nil)
        state.on = true
        monitor.refresh()
        #expect(escape.handler != nil)
        guardian.sessionEnded()
        #expect(escape.handler == nil)
        #expect(escape.registrations == 2)
    }

    @Test func aSessionThatBeginsUnderSecureInputStopsAtOnce() {
        let state = State()
        state.on = true
        let escape = FakeEscape()
        let (guardian, _) = make(state, escape)
        var stops = 0
        guardian.onStop = { stops += 1 }
        guardian.onEscape = {}
        guardian.sessionBegan()
        #expect(stops == 1)
        #expect(escape.handler != nil)
        guardian.sessionEnded()
    }

    @Test func secondListenerGetsTheChangeToo() {
        let state = State()
        let monitor = SecureInputMonitor(isOn: { state.on }, ownerPID: { nil }, observe: false)
        var first: [Bool] = []
        var second: [Bool] = []
        monitor.onChange = { first.append($0) }
        let token = monitor.addListener { second.append($0) }
        state.on = true
        monitor.refresh()
        monitor.removeListener(token)
        state.on = false
        monitor.refresh()
        #expect(first == [true, false])
        #expect(second == [true])
    }
}
