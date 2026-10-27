// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// What the Settings search can find. SwiftUI's `Text` is opaque, so the rows
/// are listed here: the section, the English key of the row's title (as in
/// Localizable.strings or Voice.strings) and the anchor the row carries in its
/// pane (`anchor:` of `PKRow` / `PKGroup`, or `.pkAnchor`). The apps, sites and
/// words you added have their own filters and are not here.
/// scripts/check-settings-index.py compares this list with the panes.
enum SettingsIndex {
    /// The localized title and the English key of every row: a query finds either.
    static let search = SettingsSearch(entries: entries.map { entry in
        let localized = entry.voice
            ? String(localized: String.LocalizationValue(entry.key), table: "Voice")
            : String(localized: String.LocalizationValue(entry.key))
        return SearchEntry(section: entry.section, anchor: entry.anchor, texts: [localized, entry.key],
                           requires: Set(entry.requires.map(\.rawValue)))
    })

    private struct Entry {
        let section: SettingsSection
        let key: String
        let anchor: String
        var voice = false
        let requires: [SettingsFlag]
    }

    /// `requires`: what the window must show for the row to be there (`SettingsFlag`).
    private static func item(_ section: SettingsSection, _ key: String, _ anchor: String,
                             _ requires: SettingsFlag...) -> Entry {
        Entry(section: section, key: key, anchor: anchor, requires: requires)
    }

    /// A string of Voice.strings.
    private static func voiceItem(_ section: SettingsSection, _ key: String, _ anchor: String,
                                  _ requires: SettingsFlag...) -> Entry {
        Entry(section: section, key: key, anchor: anchor, voice: true, requires: requires)
    }

    /// In the order of the sidebar and of each pane.
    private static var entries: [Entry] {
        var list: [Entry] = [
            item(.general, "General", "title"),
            item(.general, "Your languages", "general.languages", .languageChoice),
            item(.general, "Corrections", "general.corrections"),
            item(.general, "Correct typos", "general.typos"),
            item(.general, "Double capitals", "general.double-capitals"),
            item(.general, "Accidental Caps Lock", "general.caps-lock-fix"),
            item(.general, "Abbreviations", "general.abbreviations"),
            item(.general, "Letter ё", "general.yo"),
            item(.general, "Hyphen", "general.hyphen"),
            item(.general, "Retype a phrase", "general.retype-phrase"),
            item(.general, "Hint", "general.hint"),
            item(.general, "Hint at the caret", "general.hint-caret"),
            item(.general, "Menu bar", "general.menu-bar"),
            item(.general, "Icon", "general.menu-icon"),
            item(.general, "Show the icon", "general.menu-visibility"),
            item(.general, "Menu", "general.menu"),
            item(.general, "Automatic switching and mode", "general.menu-mode"),
            item(.general, "Recent corrections", "general.menu-corrections"),
        ]
        #if PEREKEY_VOICE
        list += [voiceItem(.general, "Recent dictations", "general.menu-dictations", .voiceOn)]
        #endif
        list += [
            item(.general, "Pause for 1 hour", "general.menu-pause"),
            item(.general, "Launch at login", "general.menu-launch"),
        ]
        #if PEREKEY_VOICE
        list += [voiceItem(.general, "Voice mode", "general.menu-voice-mode", .voiceOn)]
        #endif
        list += [
            item(.general, "Layouts as a list", "general.menu-layouts"),
        ]
        #if PEREKEY_VOICE
        list += [
            voiceItem(.general, "Transcripts…", "general.menu-transcripts", .voiceOn),
            voiceItem(.general, "Transcribe File…", "general.menu-transcribe", .voiceOn),
            voiceItem(.general, "Record a Call…", "general.menu-call", .voiceOn),
        ]
        #endif
        list += [
            item(.general, "Check for Updates…", "general.menu-updates"),
            item(.general, "How to Use Perekey", "general.menu-how-to"),
            item(.general, "About Perekey", "general.menu-about"),
            item(.general, "Count for today", "general.menu-statistics", .usage),
            item(.general, "Sounds", "general.sounds"),
            item(.general, "Sound on layout switch", "general.sound-switch"),
            item(.general, "Sound on correction", "general.sound-correction"),
            item(.general, "Startup", "general.startup"),
            item(.general, "Launch at login", "general.launch-at-login"),
            item(.general, "Updates", "general.updates"),
            item(.general, "Check for updates automatically", "general.updates-automatic"),
            item(.general, "Last check", "general.updates-last"),
            item(.general, "Help", "general.help"),
            item(.general, "How to Use Perekey", "general.how-to"),

            item(.shortcuts, "Shortcuts", "title"),
            item(.shortcuts, "Preset", "shortcuts.preset"),
            item(.shortcuts, "Switch layout", "shortcuts.switch-layout"),
            item(.shortcuts, "Retype last word or selection", "shortcuts.retype"),
            item(.shortcuts, "Turn automatic switching on or off", "shortcuts.autoswitch"),
            item(.shortcuts, "Undo last correction", "shortcuts.undo"),
            item(.shortcuts, "Change case of the word or selection", "shortcuts.change-case"),
            item(.shortcuts, "Transliterate the selection", "shortcuts.transliterate"),
            item(.shortcuts, "Paste without formatting", "shortcuts.paste-plain"),
            item(.shortcuts, "Caps Lock", "shortcuts.caps-lock"),
            item(.shortcuts, "How to use Caps Lock", "shortcuts.caps-lock-mode"),
        ]
        #if PEREKEY_VOICE
        list += [
            voiceItem(.voice, "Voice", "title", .voice),
            voiceItem(.voice, "Voice input", "voice.input", .voiceSupported),
            voiceItem(.voice, "Shortcut", "voice.shortcut", .voiceActive),
            voiceItem(.voice, "Model", "voice.models", .voiceActive),
            voiceItem(.voice, "Model for transcriptions", "voice.transcription-model", .voiceActive),
            voiceItem(.voice, "Unload the model after", "voice.unload", .voiceActive),
            voiceItem(.voice, "Dictation", "voice.dictation", .voiceActive),
            voiceItem(.voice, "Microphone", "voice.microphone", .voiceActive),
            voiceItem(.voice, "Switch the layout to the language of the phrase", "voice.switch-layout", .voiceActive),
            voiceItem(.voice, "Sounds", "voice.sounds", .voiceActive),
            voiceItem(.voice, "Stop by itself after", "voice.auto-stop", .voiceActive),
            voiceItem(.voice, "Text", "voice.text", .voiceText),
            voiceItem(.voice, "Remove filler words", "voice.fillers", .voiceText),
            voiceItem(.voice, "History", "voice.history", .voiceText),
            voiceItem(.voice, "Keep dictations for", "voice.history-retention", .voiceText),
            voiceItem(.voice, "Keep the audio of dictations", "voice.history-audio", .voiceText),
            voiceItem(.voice, "Recordings", "voice.recordings", .voiceRecordings),
            voiceItem(.voice, "Record and transcribe", "voice.record-transcribe", .voiceRecordings),
            voiceItem(.voice, "Transcripts", "voice.transcripts", .voiceTranscripts),
            voiceItem(.voice, "Keep the audio of calls", "voice.call-audio", .voiceRecordings),
            voiceItem(.voice, "Include in Time Machine", "voice.time-machine", .voiceRecordings),
            voiceItem(.voice, "Model for summaries", "voice.summary-model", .voiceSummaries),

            voiceItem(.voiceModes, "Voice modes", "title", .voiceModes),
            voiceItem(.voiceModes, "Where the LLM works", "modes.llm", .voiceModesSupported),
            voiceItem(.voiceModes, "Your address", "modes.address", .voiceModesSupported),
        ]
        #endif
        list += [
            item(.apps, "Apps", "title"),

            item(.sites, "Sites", "title"),

            item(.words, "Words", "title"),
            item(.words, "Don't touch: mine", "words.mine"),
            item(.words, "Don't touch: learned", "words.learned"),
            item(.words, "Learn from undone corrections", "words.learn"),
            item(.words, "Always fix", "words.always"),

            item(.privacy, "Privacy", "title"),
            item(.privacy, "Perekey does not touch", "privacy.guarantees"),
            item(.privacy, "Password fields", "privacy.password-fields"),
            item(.privacy, "Strings that look like passwords", "privacy.password-like"),
            item(.privacy, "Random letters, as in a captcha", "privacy.captcha"),
            item(.privacy, "Code in terminals and editors", "privacy.code"),
            item(.privacy, "Statistics", "privacy.statistics", .usage),
            item(.privacy, "Count corrections", "privacy.count", .usage),
            item(.privacy, "Erase the counts", "privacy.erase-counts", .statisticsOn),
            item(.privacy, "Languages of apps", "privacy.languages", .languageStats),
            item(.privacy, "Forget the languages of apps", "privacy.forget-languages", .languageStats),
            item(.privacy, "Settings file", "privacy.file"),
            item(.privacy, "Back up or move settings", "privacy.backup"),
            item(.privacy, "Feedback", "privacy.feedback"),
            item(.privacy, "A wrong correction?", "privacy.report"),
        ]
        return list
    }
}
