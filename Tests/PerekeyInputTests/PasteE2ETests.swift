// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Testing
@testable import PerekeyInput

/// A real paste into the frontmost app, for scripts/e2e-paste.sh. Skipped
/// unless `PEREKEY_E2E_PASTE` holds the text: it posts ⌘V and uses the general
/// pasteboard (the user's contents are put back at the end).
///
/// `PEREKEY_E2E_MODE`:
/// - `paste`: the text must arrive and the pasteboard come back;
/// - `secure`: the focus is a password field, nothing may be touched;
/// - `changed`: `PEREKEY_E2E_SWITCH_TO` (a bundle ID) is activated between
///   the capture and the paste, nothing may be touched;
/// - `lost`: ⌘V is "lost" (not posted), the pasteboard must come back anyway.
///
/// `PEREKEY_E2E_STRATEGY` picks a `PasteStrategy` other than ⌘V.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PEREKEY_E2E_PASTE"] != nil),
       .serialized)
struct PasteE2ETests {
    private let env = ProcessInfo.processInfo.environment

    @Test func pasteIntoTheFrontmostApp() async throws {
        let text = try #require(env["PEREKEY_E2E_PASTE"])
        let mode = env["PEREKEY_E2E_MODE"] ?? "paste"
        #expect(AXIsProcessTrusted(), "the terminal needs Accessibility")
        let pasteboard = NSPasteboard.general
        let users = pasteboard.snapshot()
        defer { pasteboard.restore(users) }
        Self.seed(pasteboard)
        let before = pasteboard.snapshot()
        let app = NSWorkspace.shared.frontmostApplication
        if let app { Self.askForAccessibilityTree(app.processIdentifier) }

        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .milliseconds(600)) {
            if mode != "lost" { PlainPaste.postCommandV(keyCode: 9) } // kVK_ANSI_V
        }
        let paster = TextPaster(plainPaste: plain) {}
        if let strategy = env["PEREKEY_E2E_STRATEGY"].flatMap(PasteStrategy.init(rawValue:)) {
            paster.strategy = strategy
        }
        let reader = PasteTargetReader()
        let target = await paster.captureTarget()

        if mode == "changed", let other = env["PEREKEY_E2E_SWITCH_TO"] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: other).first
            running?.activate()
            try await Task.sleep(for: .milliseconds(500))
        } else {
            try await Task.sleep(for: .milliseconds(300))
        }
        let again = await reader.current()
        let changeCount = pasteboard.changeCount
        let result = await paster.paste(text, into: target)
        let touched = pasteboard.changeCount != changeCount

        // Wait for the restore, then for the app to show the text.
        for _ in 0..<100 where plain.isRestorePending { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        let value = await Self.focusedValue()
        let restored = pasteboard.snapshot() == before
        let inserted = value?.contains(text) ?? false

        let line = [
            "PASTE-E2E app=\(app?.bundleIdentifier ?? "?")",
            "mode=\(mode)",
            "strategy=\(paster.strategy.rawValue)",
            "result=\(result)",
            "inserted=\(inserted)",
            "touched=\(touched)",
            "restored=\(restored)",
            "role=\(target?.element?.role ?? "-")",
            "id=\(target?.element?.identifier ?? "-")",
            "window=\(target?.window != nil)",
            "sameRef=\(target?.element?.ref == again?.element?.ref)",
            "sameTarget=\(again.map { target?.isSame(as: $0) ?? false } ?? false)",
        ].joined(separator: " ")
        print(line)

        #expect(restored, "the pasteboard is the user's again")
        switch mode {
        case "paste":
            #expect(result == .pasted)
            #expect(inserted, "the field shows the text")
        case "lost":
            #expect(result == .pasted)
            #expect(!inserted)
        case "secure":
            #expect(result == .secureField)
            #expect(!touched)
        case "changed":
            #expect(result == .targetChanged)
            #expect(!touched)
        default:
            Issue.record("unknown mode \(mode)")
        }
    }

    /// Rich contents, so the restore has more than plain text to bring back.
    private static func seed(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("perekey-e2e clipboard", forType: .string)
        item.setData(Data("<b>perekey-e2e clipboard</b>".utf8), forType: .html)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("app.perekey.e2e.custom"))
        pasteboard.writeObjects([item])
    }

    /// What the app does through `FocusObserver`: Chromium builds its tree on request.
    private static func askForAccessibilityTree(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    private static func focusedValue() async -> String? {
        await Task.detached {
            let systemWide = AXUIElementCreateSystemWide()
            var element: CFTypeRef?
            guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &element)
                == .success, let element, CFGetTypeID(element) == AXUIElementGetTypeID()
            else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(unsafeDowncast(element, to: AXUIElement.self),
                                                kAXValueAttribute as CFString, &value) == .success
            else { return nil }
            return value as? String
        }.value
    }
}
