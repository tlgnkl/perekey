// SPDX-License-Identifier: GPL-3.0-or-later
//
// The real machine under `perekey-e2e play`: CGEvent for the keys, Accessibility for the text of the
// field, the input sources for the layout, and the readings the guard stops on (the lock of the screen,
// the idle time of the keyboard and the mouse). The logic is in PerekeyEvalKit and has tests; this file
// is only what talks to the system, and the tests do not run it.

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit
import PerekeyCore
import PerekeyEvalKit

struct MacPlatform: AppPlatform {
    var probe: InputGuard.Probe {
        InputGuard.Probe(
            screenLocked: Self.screenIsLocked,
            idleSeconds: Self.hidIdleSeconds,
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            now: { ProcessInfo.processInfo.systemUptime }
        )
    }

    func enabledLayouts() -> Set<String>? {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return Set(list.compactMap(Self.id))
    }

    func makeDriver(bundle: String) throws -> any AppDriver {
        try MacDriver(bundle: bundle)
    }

    /// True when the screen is locked, and also when there is no session to ask or it is not the one on the
    /// console: the keys of the bench would not reach the app then either.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }

    /// `HIDIdleTime` of `IOHIDSystem`, nanoseconds since the last keyboard or mouse input.
    static func hidIdleSeconds() -> Double? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.doubleValue / 1_000_000_000
    }

    static func id(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

struct DriverError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// TextEdit: one document window, its text area focused.
final class MacDriver: AppDriver {
    private let bundle: String
    private let app: NSRunningApplication
    private let source = CGEventSource(stateID: .hidSystemState)

    init(bundle: String) throws {
        guard AXIsProcessTrusted() else {
            throw DriverError("this terminal has no Accessibility access (System Settings > Privacy & Security)")
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            throw DriverError("\(bundle) is not running: open it with an empty document first")
        }
        self.bundle = bundle
        app = running
    }

    func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func sleep(_ seconds: Double) {
        if seconds > 0 { usleep(UInt32(seconds * 1_000_000)) }
    }

    /// Waits for `condition` up to `seconds`.
    private func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let end = now() + seconds
        while now() < end {
            if condition() { return true }
            sleep(0.05)
        }
        return condition()
    }

    private func activate(_ target: NSRunningApplication) throws {
        target.activate()
        guard wait(3, until: { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier }) else {
            throw DriverError("\(target.bundleIdentifier ?? "app") did not come to the front")
        }
    }

    private func field() throws -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { throw DriverError("\(bundle) has no focused field: click into the document") }
        return focused as! AXUIElement // swiftlint:disable:this force_cast
    }

    func readText() throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(try field(), kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { throw DriverError("cannot read the text of the field") }
        return text
    }

    func currentLayout() -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "unknown" }
        return MacPlatform.id(source) ?? "unknown"
    }

    private func select(layout id: String) throws {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let target = list.first else { throw DriverError("the layout \(id) is not enabled") }
        guard TISSelectInputSource(target) == noErr else { throw DriverError("the system refused the layout \(id)") }
        guard wait(2, until: { currentLayout() == id }) else {
            throw DriverError("the system did not confirm the layout \(id) (in force: \(currentLayout()))")
        }
    }

    /// A new field, as the stand's: the focus goes to Finder and back, so Perekey forgets the words of the
    /// last case; the text is emptied through Accessibility, which posts no key; the layout is chosen and
    /// confirmed. Escape ends a word that is left in Perekey's buffer.
    func prepare(start: String) throws {
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            try activate(finder)
        }
        try activate(app)
        let target = try field()
        guard AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, "" as CFString) == .success,
              wait(2, until: { (try? readText()) == "" }) else { throw DriverError("cannot empty the field") }
        try perform(.keyDown(code: UInt16(kVK_Escape), flags: 0))
        try perform(.keyUp(code: UInt16(kVK_Escape), flags: 0))
        try select(layout: start)
    }

    func perform(_ action: AppAction) throws {
        switch action {
        case let .keyDown(code, flags): try post(code, flags: flags, down: true, modifier: false)
        case let .keyUp(code, flags): try post(code, flags: flags, down: false, modifier: false)
        case let .modifier(code, flags): try post(code, flags: flags, down: true, modifier: true)
        case let .layout(id): try select(layout: id)
        }
    }

    private func post(_ code: UInt16, flags: UInt64, down: Bool, modifier: Bool) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw DriverError("cannot create an event")
        }
        if modifier { event.type = .flagsChanged }
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }
}
