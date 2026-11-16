// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import PerekeyCore
import Testing
@testable import PerekeyInput

/// Runs against private pasteboards only: never `NSPasteboard.general`.
@MainActor
@Suite struct PasteboardCopierTests {
    private static let custom = NSPasteboard.PasteboardType("app.perekey.test.custom")

    /// A private pasteboard with two items and several types, released after `body`.
    private func withPasteboard(_ body: (NSPasteboard) async throws -> Void) async rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.perekey.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("user's text", forType: .string)
        first.setData(Data([0, 1, 2, 255]), forType: Self.custom)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        pasteboard.writeObjects([first, second])
        try await body(pasteboard)
    }

    private func contents(of pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }

    /// Plays the app answering ⌘C.
    private func appCopies(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @Test func readsCopyAndRestoresEverything() async {
        await withPasteboard { pasteboard in
            let before = contents(of: pasteboard)
            let copier = PasteboardCopier(pasteboard: pasteboard)
            let text = await copier.copySelection(bundleID: "com.apple.TextEdit") {
                appCopies("ghbdtn", to: pasteboard)
            }
            #expect(text == "ghbdtn")
            #expect(contents(of: pasteboard) == before)
            #expect(pasteboard.types?.contains(PasteboardCopier.transientType) != true, "no markers left")
        }
    }

    @Test func nothingCopiedLeavesPasteboardUntouched() async {
        await withPasteboard { pasteboard in
            let changeCount = pasteboard.changeCount
            let copier = PasteboardCopier(pasteboard: pasteboard, timeout: .milliseconds(30), lateWindow: .zero)
            let text = await copier.copySelection(bundleID: nil) {}
            #expect(text.isEmpty)
            #expect(pasteboard.changeCount == changeCount)
        }
    }

    @Test func lateCopyIsUndone() async throws {
        try await withPasteboard { pasteboard in
            let before = contents(of: pasteboard)
            let copier = PasteboardCopier(pasteboard: pasteboard, timeout: .milliseconds(20),
                                          lateWindow: .milliseconds(400))
            let text = await copier.copySelection(bundleID: nil) {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    appCopies("late", to: pasteboard)
                }
            }
            #expect(text.isEmpty)
            #expect(copier.isBusy)
            for _ in 0..<50 where copier.isBusy {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!copier.isBusy)
            #expect(contents(of: pasteboard) == before)
        }
    }

    @Test func emptyPasteboardStaysEmpty() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.perekey.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let text = await PasteboardCopier(pasteboard: pasteboard).copySelection(bundleID: nil) {
            appCopies("руддщ", to: pasteboard)
        }
        #expect(text == "руддщ")
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func lineCopyInEditorsIsNoSelection() async {
        await withPasteboard { pasteboard in
            let before = contents(of: pasteboard)
            let text = await PasteboardCopier(pasteboard: pasteboard).copySelection(bundleID: "com.microsoft.VSCode") {
                appCopies("let x = 1\n", to: pasteboard)
            }
            #expect(text.isEmpty)
            #expect(contents(of: pasteboard) == before)
        }
    }

    @Test func lineCopyApps() {
        #expect(PasteboardCopier.isLineCopy("line\n", bundleID: "com.microsoft.VSCode"))
        #expect(PasteboardCopier.isLineCopy("line\n", bundleID: "com.jetbrains.intellij"))
        #expect(!PasteboardCopier.isLineCopy("word", bundleID: "com.microsoft.VSCode"))
        #expect(!PasteboardCopier.isLineCopy("line\n", bundleID: "com.apple.TextEdit"))
        #expect(!PasteboardCopier.isLineCopy("line\n", bundleID: nil))
    }
}

@Suite struct CaretCheckTests {
    @Test func matchingTextBeforeCaret() {
        #expect(CaretCheck.verdict(expected: "ghbdtn ", around: "ghbdtn ") == .match)
        #expect(CaretCheck.verdict(expected: "ghbdtn ", around: "ghbdtn x") == .match, "text after the caret")
        #expect(CaretCheck.verdict(expected: "ghbdtn ", around: "ghbdtn\u{00A0}") == .match, "browser no-break space")
    }

    @Test func autocorrectIsMismatch() {
        #expect(CaretCheck.verdict(expected: "teh ", around: "the ") == .mismatch)
        #expect(CaretCheck.verdict(expected: "привет ", around: "Привет ") == .matchRaised, "macOS raised the first letter")
        #expect(CaretCheck.verdict(expected: "привет ", around: "ПРивет ") == .mismatch)
        #expect(CaretCheck.verdict(expected: "ghbdtn", around: "ghb") == .mismatch, "shorter")
    }

    @Test func autoClosedBracketIsMismatch() {
        #expect(CaretCheck.verdict(expected: "[jhjij", around: "[jhjij") == .match)
        #expect(CaretCheck.verdict(expected: "[", around: "[]") == .mismatch)
        #expect(CaretCheck.verdict(expected: "'nj'", around: "'nj''") == .mismatch)
        #expect(CaretCheck.verdict(expected: "[", around: "[x") == .match)
    }

    @Test func utf16Offsets() {
        // AX ranges count UTF-16 units: an emoji takes two.
        #expect(CaretCheck.verdict(expected: "🙂ab", around: "🙂ab ") == .match)
    }
}

/// What the engine does with a verdict (`InputEngine.postIfPending` asks `RetypeGate`).
@Suite struct RetypeGateTests {
    static let retype = Retype(
        deleteCount: 6, keys: [Retype.Key(stroke: KeyStroke(5), text: "g"), Retype.Key(stroke: KeyStroke(4), text: "h")],
        target: "com.apple.keylayout.ABC", expected: "привет", seq: 3, origin: .manual(.convertLastWord))

    @Test func aMatchPostsAndVerifiesTheBackspaces() {
        #expect(RetypeGate.decide(Self.retype, verdict: .match, hasSnapshot: true) == .go(Self.retype, verify: true))
    }

    /// The path of "Привет " in TextEdit: the word comes back raised, and is checked after the Backspaces.
    @Test func aRaisedMatchBringsTheWordBackRaised() {
        #expect(RetypeGate.decide(Self.retype, verdict: .matchRaised, hasSnapshot: true)
            == .go(Self.retype.raisingFirstLetter(), verify: true))
        #expect(Self.retype.raisingFirstLetter().text == "Gh")
    }

    @Test func aMismatchCancels() {
        guard case .cancel = RetypeGate.decide(Self.retype, verdict: .mismatch, hasSnapshot: false) else {
            Issue.record("a mismatch posts nothing")
            return
        }
    }

    /// A field AX normally answers for, now silent: no blind retype.
    @Test func anUnreadableFieldCancels() {
        guard case .cancel = RetypeGate.decide(Self.retype, verdict: .unreadable, hasSnapshot: false) else {
            Issue.record("an unreadable field posts nothing")
            return
        }
    }

    /// A field AX never answers for (terminals, lagging apps): as it always was, all at once, unchecked.
    @Test func anUnavailableFieldIsRetypedBlind() {
        #expect(RetypeGate.decide(Self.retype, verdict: .unavailable, hasSnapshot: false) == .go(Self.retype, verify: false))
        #expect(RetypeGate.decide(Self.retype, verdict: nil, hasSnapshot: false) == .go(Self.retype, verify: false))
    }

    @Test func aRetypeWithNothingToHoldBackIsPostedWhole() {
        var selection = Self.retype
        selection.deleteCount = 0
        #expect(RetypeGate.decide(selection, verdict: .match, hasSnapshot: true) == .go(selection, verify: false))
        var viaAX = Self.retype
        viaAX.viaAccessibility = true
        #expect(RetypeGate.decide(viaAX, verdict: .match, hasSnapshot: true) == .go(viaAX, verify: false))
    }
}
