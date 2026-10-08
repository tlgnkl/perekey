// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import os
import PerekeyCore

/// Reads the selected text for `Effect.convertSelection`.
///
/// First through accessibility (`TextProbe`, on its own thread). If AX cannot
/// tell, through the pasteboard on the main thread: copy with ⌘C, read, put
/// the user's pasteboard back (`PasteboardCopier`).
@MainActor
public final class SelectionReader {
    public struct Selection: Hashable, Sendable {
        /// Empty if nothing is selected or it could not be read.
        public var text: String
        /// Replace it through AX: it came from AX and the app is opted in.
        public var viaAccessibility: Bool
    }

    /// Apps where the selection is replaced through AX instead of typing.
    /// Off for every app by default: in many apps AX replacement breaks ⌘Z
    /// and formatting. Gets the bundle ID of the frontmost app.
    public var replacesViaAccessibility: (String?) -> Bool = { _ in false }

    private let probe: TextProbe
    private let copier: PasteboardCopier
    private var reading = false
    private let log = Logger(subsystem: "app.perekey", category: "selection")

    public init(probe: TextProbe, pasteboard: NSPasteboard = .general) {
        self.probe = probe
        copier = PasteboardCopier(pasteboard: pasteboard)
    }

    /// Reads the selection of the frontmost app. `copyKeyCode` is the key that
    /// types "c" in the layout macOS uses for shortcuts; ⌘C is posted on it,
    /// marked `.own(seq:last: false)` so Perekey's tap lets it through the fence.
    public func read(seq: UInt32, copyKeyCode: UInt16 = 8) async -> Selection {
        // Two reads at once would snapshot each other's copy and leave it on
        // the pasteboard. A fence that timed out lets a second shortcut in.
        guard !reading, !copier.isBusy else {
            log.info("Selection read \(seq, privacy: .public) skipped: another is running")
            return Selection(text: "", viaAccessibility: false)
        }
        reading = true
        defer { reading = false }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let started = ContinuousClock.now
        let probe = probe
        let viaAX = await withCheckedContinuation { continuation in
            probe.selectedText { continuation.resume(returning: $0) }
        }
        if case let .text(text) = viaAX {
            log.info("Selection via AX: \(text.count, privacy: .public) characters in \(Self.ms(since: started), privacy: .public) ms")
            return Selection(text: text, viaAccessibility: !text.isEmpty && replacesViaAccessibility(bundleID))
        }
        let text = await copier.copySelection(bundleID: bundleID) {
            Self.postCopy(keyCode: copyKeyCode, seq: seq)
        }
        log.info("Selection via pasteboard: \(text.count, privacy: .public) characters in \(Self.ms(since: started), privacy: .public) ms")
        return Selection(text: text, viaAccessibility: false)
    }

    /// Posts ⌘C. Flags are Command only, whatever the user holds.
    static func postCopy(keyCode: UInt16, seq: UInt32) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticMark.own(seq: seq, last: false).userData)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }
}

/// The pasteboard way to read a selection: copy, read, restore.
///
/// The user's pasteboard must never stay changed. Every item and type is saved
/// first and written back after. The copied selection is marked
/// `org.nspasteboard.TransientType` and `ConcealedType` as soon as it shows
/// up, so clipboard managers that look later skip it (nspasteboard.org).
@MainActor
final class PasteboardCopier {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Editors that copy the whole line on ⌘C without a selection. A copy that
    /// ends with a line break counts as "nothing selected" there.
    static let lineCopyApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.visualstudio.code.oss",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "com.sublimetext.3", "com.sublimetext.4",
    ]

    private let pasteboard: NSPasteboard
    /// Still watching for a late copy: another copy now would be mistaken for it.
    private(set) var isBusy = false
    /// How long to wait for the app to answer ⌘C.
    private let timeout: Duration
    private let pollInterval: Duration
    /// After a timeout, how long a late copy is still undone.
    private let lateWindow: Duration

    init(pasteboard: NSPasteboard, timeout: Duration = .milliseconds(150), pollInterval: Duration = .milliseconds(5),
         lateWindow: Duration = .milliseconds(500))
    {
        self.pasteboard = pasteboard
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.lateWindow = lateWindow
    }

    static func isLineCopy(_ text: String, bundleID: String?) -> Bool {
        guard let bundleID, text.last?.isNewline == true else { return false }
        return lineCopyApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
            || bundleID == "com.google.android.studio"
    }

    /// Runs `copy` (posts ⌘C) and returns the copied text, empty if nothing
    /// came within the timeout. The pasteboard is as it was before on return.
    func copySelection(bundleID: String?, copy: () -> Void) async -> String {
        let snapshot = PasteboardSnapshot(of: pasteboard)
        let before = pasteboard.changeCount
        copy()

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while pasteboard.changeCount == before, clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        guard pasteboard.changeCount != before else {
            // Nothing selected, or a slow app. A copy that lands later would
            // replace the user's pasteboard: undo it for a while.
            isBusy = true
            Task { await undoLateCopy(of: snapshot, after: before) }
            return ""
        }

        markTransient()
        let text = pasteboard.string(forType: .string) ?? ""
        snapshot.restore(to: pasteboard)
        return Self.isLineCopy(text, bundleID: bundleID) ? "" : text
    }

    private func markTransient() {
        // Adds to the item the app wrote; does not replace it.
        pasteboard.addTypes([Self.transientType, Self.concealedType], owner: nil)
        pasteboard.setData(Data(), forType: Self.transientType)
        pasteboard.setData(Data(), forType: Self.concealedType)
    }

    private func undoLateCopy(of snapshot: PasteboardSnapshot, after changeCount: Int) async {
        defer { isBusy = false }
        let clock = ContinuousClock()
        let deadline = clock.now + lateWindow
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            let now = pasteboard.changeCount
            guard now != changeCount else { continue }
            // One change is the late copy; more means the user copied too.
            if now == changeCount + 1 {
                markTransient()
                snapshot.restore(to: pasteboard)
            }
            return
        }
    }
}

/// Every item of a pasteboard with every type's data, to put back exactly.
///
/// Reading a promised type makes its owner render it; a large image copied
/// in an editor costs its full size in memory for a moment.
struct PasteboardSnapshot {
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    @MainActor
    init(of pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    @MainActor
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
