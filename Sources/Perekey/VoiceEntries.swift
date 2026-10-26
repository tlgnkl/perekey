// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyVoiceCore
import SwiftUI

/// «Записать созвон…», «Расшифровать файл…» and «Расшифровки…» outside the
/// menu: Settings → Voice and the Transcripts window carry them, so a hidden
/// menu bar item does not hide the features. They run what the menu runs, under
/// the menu's rules: a call needs `isAvailable`, a file the queue.
@MainActor
struct VoiceEntries {
    let call: CallRecordingController
    let chooseFiles: () -> Void
    let openTranscripts: () -> Void

    /// The picker, or the stop while a call is recorded. The app comes to the front first:
    /// the picker takes the keyboard, and a click in Settings must not leave it with the window.
    func recordOrStop() {
        if !call.isRecording { NSApp.activate() }
        call.menuAction()
    }

    func transcribeFile() {
        NSApp.activate()
        chooseFiles()
    }
}

/// The two commands as buttons, for Settings and the Transcripts window.
struct VoiceEntryButtons: View {
    let controller: TranscriptsController
    var small = false

    var body: some View {
        if let entries = controller.entries {
            // The narrow list column stacks them: «Расшифровать файл…» does not fit beside the other.
            let layout = small ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if entries.call.isAvailable {
                    styled(Button { entries.recordOrStop() } label: {
                        entries.call.isRecording ? voiceText("Stop Recording") : voiceText("Record a Call…")
                    })
                }
                styled(Button { entries.transcribeFile() } label: { voiceText("Transcribe File…") })
                    .disabled(controller.queue == nil)
                    .help(controller.queue == nil ? voiceString("Transcribe File… is unavailable: voice input is off.") : "")
            }
            .fixedSize(horizontal: !small, vertical: false)
        }
    }

    @ViewBuilder private func styled(_ button: some View) -> some View {
        if small {
            button.buttonStyle(.pkSmall)
        } else {
            button.buttonStyle(.pkSecondary)
        }
    }
}
#endif
