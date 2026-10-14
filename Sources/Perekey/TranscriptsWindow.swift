// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import SwiftUI

/// Owns the «Расшифровки» window: a plain `NSWindow`, as the Settings window
/// is, kept after closing so it reopens where it was.
@MainActor
final class TranscriptsWindow: NSObject, NSWindowDelegate {
    let controller: TranscriptsController
    private var window: NSWindow?

    init(controller: TranscriptsController) {
        self.controller = controller
    }

    func show() {
        let window = window ?? make()
        controller.reload()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let host = NSHostingView(rootView: TranscriptsView(controller: controller)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = voiceString("Transcripts")
        window.contentView = host
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("PerekeyTranscripts")
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // The recording must not keep playing in a window nobody sees.
        controller.player.stop()
    }
}

/// The menu's entry to the window. «Расшифровать файл…» and «Записать
/// созвон» sit in the same place, each with its own row.
struct TranscriptsMenu {
    let isOn: @MainActor () -> Bool
    let open: @MainActor () -> Void
}
#endif
