// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoiceCore

/// The text rules and the dictation history for the rest of the app: the
/// settings (`voice-text.json`) and the history (`History/history.json`).
/// Lives as long as the app, like `VoiceModelsController`.
@MainActor
final class VoiceTextController {
    let text: VoiceTextStore
    let history: DictationHistory

    init(managed: ManagedSettings = ManagedPreferences.read(), textFile: VoiceTextSettingsFile? = VoiceTextSettingsFile(),
         historyFile: DictationHistoryFile = DictationHistoryFile())
    {
        let text = VoiceTextStore(file: textFile, managed: managed)
        self.text = text
        history = DictationHistory(file: historyFile, managed: managed, settings: { text.settings })
        // A shorter term or the audio switched off cleans at once.
        let history = history
        text.observe { history.settingsChanged() }
    }

    /// What the menu shows and does with the recent dictations.
    func menu(pasteAgain: (@MainActor (HistoryEntry) -> Void)? = nil) -> DictationMenu {
        DictationMenu(history: history, text: text, pasteAgain: pasteAgain)
    }
}

/// The "Recent dictations" part of the menu: the data and the actions.
struct DictationMenu {
    let history: DictationHistory
    let text: VoiceTextStore
    /// nil hides "Paste again": nothing can paste on the user's behalf.
    var pasteAgain: (@MainActor (HistoryEntry) -> Void)?

    @MainActor func copy(_ entry: HistoryEntry) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(entry.text, forType: .string)
    }
}
#endif
