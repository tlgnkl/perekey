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

/// What the bench writes into `eventSourceUserData` of every key it posts. Not Perekey's mark
/// (`SyntheticMark`): Perekey must go on taking these keys as a person's, which is the point of the test.
let benchMark: Int64 = 0x4245 << 48 // "BE"

/// A listen-only tap on the keyboard of the session that remembers the last key which is neither the
/// bench's nor Perekey's retype: a person's. It sees what `HIDIdleTime` cannot, a key between two keys of
/// the bench. Needs Input Monitoring; without it `make` returns nil and the guard falls back (docs/eval.md).
final class HumanKeyWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double?
    private var tap: CFMachPort?

    static func make() -> HumanKeyWatch? {
        guard CGPreflightListenEventAccess() else { return nil }
        let watch = HumanKeyWatch()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread {
            let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                | 1 << CGEventType.flagsChanged.rawValue
            let refcon = Unmanaged.passUnretained(watch).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    let watch = Unmanaged<HumanKeyWatch>.fromOpaque(refcon!).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        watch.tapLost()
                    } else {
                        watch.saw(event)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: refcon
            ) else { started.signal(); return }
            watch.begin(tap)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "perekey-e2e.human-key-watch"
        thread.start()
        started.wait()
        return watch.isRunning ? watch : nil
    }

    fileprivate func begin(_ tap: CFMachPort) {
        lock.lock()
        self.tap = tap
        lock.unlock()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    private func saw(_ event: CGEvent) {
        let data = event.getIntegerValueField(.eventSourceUserData)
        if data == benchMark { return }
        // Perekey's own keys are not a person's; a key of the person that Perekey held back and posts again is.
        if let mark = SyntheticMark(userData: data), mark != .replayed { return }
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// The system switched the tap off: keys may have gone unseen, so count it as a person's key.
    private func tapLost() {
        lock.lock()
        last = ProcessInfo.processInfo.systemUptime
        let tap = tap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    var lastKey: Double? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

struct MacPlatform: AppPlatform {
    private let watch = HumanKeyWatch.make()

    var probe: InputGuard.Probe {
        InputGuard.Probe(
            screenLocked: Self.screenIsLocked,
            idleSeconds: Self.hidIdleSeconds,
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            now: { ProcessInfo.processInfo.systemUptime },
            mouseIdleSeconds: Self.mouseIdleSeconds,
            lastHumanKey: watch.map { watch in { watch.lastKey } }
        )
    }

    /// The least of the times since the last mouse event of each kind. The bench posts no mouse event.
    static func mouseIdleSeconds() -> Double? {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                    .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                    .scrollWheel]
        let ages = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        guard let least = ages.min(), least >= 0 else { return nil }
        return least
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
    func prepare(start: String, beforePost: () throws -> Void) throws {
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            try activate(finder)
        }
        try activate(app)
        let target = try field()
        guard AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, "" as CFString) == .success,
              wait(2, until: { (try? readText()) == "" }) else { throw DriverError("cannot empty the field") }
        try beforePost()
        try perform(.keyDown(code: UInt16(kVK_Escape), flags: 0))
        try beforePost()
        try perform(.keyUp(code: UInt16(kVK_Escape), flags: 0))
        try beforePost()
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
        event.setIntegerValueField(.eventSourceUserData, value: benchMark)
        event.flags = CGEventFlags(rawValue: flags)
        event.post(tap: .cghidEventTap)
    }
}
