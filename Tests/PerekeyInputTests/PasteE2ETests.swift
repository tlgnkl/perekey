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
/// - `secureinput`: Secure Input is on in another process, nothing may be touched;
/// - `changed`: `PEREKEY_E2E_SWITCH_TO` (a bundle ID) is activated, or ⌘ with
///   the key code `PEREKEY_E2E_SWITCH_KEY` is pressed, between the capture
///   and the paste; nothing may be touched;
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
        let pid = app?.processIdentifier
        if let pid {
            Self.askForAccessibilityTree(pid)
            // Browsers keep the focus in the address bar after a page opens.
            if env["PEREKEY_E2E_FOCUS"] == "web" {
                let found = await Self.focusWebField(pid: pid, secure: mode == "secure")
                #expect(found, "a field of the page got the focus")
            }
        }

        let plain = PlainPaste(pasteboard: pasteboard, restoreDelay: .milliseconds(600)) {
            if mode != "lost" { PlainPaste.postCommandV(keyCode: 9) } // kVK_ANSI_V
        }
        let paster = TextPaster(plainPaste: plain) {}
        if let strategy = env["PEREKEY_E2E_STRATEGY"].flatMap(PasteStrategy.init(rawValue:)) {
            paster.strategy = strategy
        }
        let reader = PasteTargetReader()
        let target = try #require(await paster.captureTarget(), "no frontmost app")

        if mode == "changed", let other = env["PEREKEY_E2E_SWITCH_TO"] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: other).first
            running?.activate()
            try await Task.sleep(for: .milliseconds(500))
        } else if mode == "changed", let key = env["PEREKEY_E2E_SWITCH_KEY"].flatMap(UInt16.init) {
            // ⌘ and a key code as the user would press them, e.g. ⌘T for a new tab.
            Self.postCommand(key)
            try await Task.sleep(for: .milliseconds(800))
        } else {
            try await Task.sleep(for: .milliseconds(300))
        }
        let again = await reader.current(frontmostPID: pid)
        let changeCount = pasteboard.changeCount
        let result = await paster.paste(text, into: target)
        let touched = pasteboard.changeCount != changeCount

        // Wait for the restore, then for the app to show the text.
        for _ in 0..<100 where plain.isRestorePending { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        let value = await Self.focusedValue(pid: pid)
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
            "role=\(target.element?.role ?? "-")",
            "id=\(target.element?.identifier ?? "-")",
            "web=\(target.element?.webDocument ?? "-")",
            "window=\(target.window != nil)",
            "sameRef=\(target.element?.ref == again?.element?.ref)",
            "sameTarget=\(again.map(target.isSame(as:)) ?? false)",
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
        case "secureinput":
            if case .secureInput = result {} else { Issue.record("expected .secureInput, got \(result)") }
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

    /// ⌘ down, the key, ⌘ up: without the last flagsChanged the session
    /// would keep ⌘ down, and the paste would wait for it.
    private static func postCommand(_ keyCode: UInt16) {
        let source = CGEventSource(stateID: .hidSystemState)
        func command(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: down) // kVK_Command
            event?.type = .flagsChanged
            event?.flags = down ? .maskCommand : []
            event?.post(tap: .cghidEventTap)
        }
        command(true)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        command(false)
    }

    /// What the app does through `FocusObserver`: Chromium builds its tree on request.
    private static func askForAccessibilityTree(_ pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                     kCFBooleanTrue)
    }

    /// The value of the focused element of `pid`: the system-wide element
    /// does not answer a process started over SSH.
    private static func focusedValue(pid: pid_t?) async -> String? {
        guard let pid else { return nil }
        return await Task.detached {
            guard let element = focusedElement(of: pid) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
            else { return nil }
            return value as? String
        }.value
    }

    private nonisolated static func focusedElement(of pid: pid_t) -> AXUIElement? {
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXFocusedUIElementAttribute as CFString, &element) == .success,
            let element, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(element, to: AXUIElement.self)
    }

    /// Focuses the first text area or plain text field (or password field) inside a web area of
    /// the focused window. Chromium builds its tree a moment after
    /// `AXManualAccessibility`, so this tries for a while.
    private static func focusWebField(pid: pid_t, secure: Bool) async -> Bool {
        for _ in 0..<20 {
            let done = await Task.detached { () -> Bool in
                var window: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                    kAXFocusedWindowAttribute as CFString, &window) == .success,
                    let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
                    let field = findField(in: unsafeDowncast(window, to: AXUIElement.self), secure: secure,
                                          inWeb: false, depth: 0)
                else { return false }
                return AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
            }.value
            if done {
                try? await Task.sleep(for: .milliseconds(300))
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private nonisolated static func findField(in element: AXUIElement, secure: Bool, inWeb: Bool,
                                              depth: Int) -> AXUIElement?
    {
        guard depth < 40 else { return nil }
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            return value as? String
        }
        let role = string(kAXRoleAttribute)
        let web = inWeb || role == "AXWebArea"
        if web {
            let subrole = string(kAXSubroleAttribute)
            if secure, subrole == kAXSecureTextFieldSubrole { return element }
            if !secure, role == kAXTextAreaRole || (role == kAXTextFieldRole && subrole == nil) { return element }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement]
        else { return nil }
        for child in list {
            if let found = findField(in: child, secure: secure, inWeb: web, depth: depth + 1) { return found }
        }
        return nil
    }
}
