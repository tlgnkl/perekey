// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing
@testable import PerekeyInput

/// Only private, uniquely named pasteboards: never `NSPasteboard.general`.
@MainActor
@Suite struct PlainPasteTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("app.perekey.test.\(UUID().uuidString)"))
    }

    private func fill(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("Hello", forType: .string)
        rich.setData(Data("<b>Hello</b>".utf8), forType: .html)
        rich.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("app.perekey.test.custom"))
        let second = NSPasteboardItem()
        second.setString("Second", forType: .string)
        pasteboard.writeObjects([rich, second])
    }

    @Test func plainTextIsWrittenTransientAndEverythingComesBack() throws {
        let pasteboard = makePasteboard()
        fill(pasteboard)
        let before = PlainPaste.snapshot(of: pasteboard)
        #expect(before.items.count == 2)
        var seenDuringPost: PlainPaste.Snapshot?
        let paste = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) {
            seenDuringPost = PlainPaste.snapshot(of: pasteboard)
        }
        #expect(paste.paste())

        // While ⌘V is posted: plain text only, marked transient.
        let during = try #require(seenDuringPost)
        #expect(during.items.count == 1)
        let types = Set(during.items[0].map(\.type))
        #expect(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        #expect(types.contains(PlainPaste.transientType.rawValue))
        #expect(!types.contains(NSPasteboard.PasteboardType.html.rawValue))
        // The plain text of several items is joined, as the system does.
        #expect(pasteboard.string(forType: .string) == "Hello\nSecond")

        paste.restoreNow()
        #expect(PlainPaste.snapshot(of: pasteboard) == before)
        #expect(!paste.isRestorePending)
    }

    @Test func restoreHappensAfterTheDelay() async throws {
        let pasteboard = makePasteboard()
        fill(pasteboard)
        let before = PlainPaste.snapshot(of: pasteboard)
        let paste = PlainPaste(pasteboard: pasteboard, restoreDelay: .milliseconds(50)) {}
        #expect(paste.paste())
        #expect(paste.isRestorePending)
        // Wait for the restore itself, not a fixed time: a loaded machine is slow.
        for _ in 0..<100 where paste.isRestorePending { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!paste.isRestorePending)
        #expect(PlainPaste.snapshot(of: pasteboard) == before)
    }

    @Test func aCopyDuringTheDelayIsNotOverwritten() {
        let pasteboard = makePasteboard()
        fill(pasteboard)
        let paste = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) {}
        #expect(paste.paste())
        pasteboard.clearContents()
        pasteboard.setString("Newer copy", forType: .string)
        paste.restoreNow()
        #expect(pasteboard.string(forType: .string) == "Newer copy")
    }

    @Test func secondPasteKeepsTheFirstSnapshot() {
        let pasteboard = makePasteboard()
        fill(pasteboard)
        let before = PlainPaste.snapshot(of: pasteboard)
        let paste = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) {}
        #expect(paste.paste())
        #expect(paste.paste(), "the pasteboard holds Perekey's plain text now")
        paste.restoreNow()
        #expect(PlainPaste.snapshot(of: pasteboard) == before)
    }

    @Test func pasteboardWithoutTextIsUntouched() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([9, 9]), forType: .png)
        pasteboard.writeObjects([item])
        let before = PlainPaste.snapshot(of: pasteboard)
        var posted = false
        let paste = PlainPaste(pasteboard: pasteboard, restoreDelay: .seconds(60)) { posted = true }
        #expect(!paste.paste())
        #expect(!posted)
        #expect(PlainPaste.snapshot(of: pasteboard) == before)
    }
}
