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
        return SearchEntry(section: entry.section, anchor: entry.anchor, texts: [localized, entry.key])
    })

    private struct Entry {
        let section: SettingsSection
        let key: String
        let anchor: String
        var voice = false
    }

    private static func item(_ section: SettingsSection, _ key: String, _ anchor: String) -> Entry {
        Entry(section: section, key: key, anchor: anchor)
    }

    /// A string of Voice.strings.
    private static func voiceItem(_ section: SettingsSection, _ key: String, _ anchor: String) -> Entry {
        Entry(section: section, key: key, anchor: anchor, voice: true)
    }

    /// In the order of the sidebar and of each pane.
    private static var entries: [Entry] {
        var list: [Entry] = [
            item(.general, "General", "title"),
            item(.general, "Your languages", "general.languages"),
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
            item(.general, "Sounds", "general.sounds"),
            item(.general, "Sound on layout switch", "general.sound-switch"),
            item(.general, "Sound on correction", "general.sound-correction"),
            item(.general, "Updates", "general.updates"),
            item(.general, "Check for updates automatically", "general.updates-automatic"),
            item(.general, "Last check", "general.updates-last"),

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
            voiceItem(.voice, "Voice", "title"),
            voiceItem(.voice, "Voice input", "voice.input"),
            voiceItem(.voice, "Shortcut", "voice.shortcut"),
            voiceItem(.voice, "Microphone", "voice.microphone"),
            voiceItem(.voice, "Model", "voice.model"),
            voiceItem(.voice, "Model for transcriptions", "voice.transcription-model"),
            voiceItem(.voice, "Switch the layout to the language of the phrase", "voice.switch-layout"),
            voiceItem(.voice, "Sounds", "voice.sounds"),
            voiceItem(.voice, "Stop by itself after", "voice.auto-stop"),
            voiceItem(.voice, "Unload the model after", "voice.unload"),
            voiceItem(.voice, "Models", "voice.models"),
            voiceItem(.voice, "Text", "voice.text"),
            voiceItem(.voice, "Remove filler words", "voice.fillers"),
            voiceItem(.voice, "History", "voice.history"),
            voiceItem(.voice, "Keep dictations for", "voice.history-retention"),
            voiceItem(.voice, "Keep the audio of dictations", "voice.history-audio"),
            voiceItem(.voice, "Recordings", "voice.recordings"),
            voiceItem(.voice, "Keep the audio of calls", "voice.call-audio"),
            voiceItem(.voice, "Include in Time Machine", "voice.time-machine"),
            voiceItem(.voice, "Model for summaries", "voice.summary-model"),

            voiceItem(.voiceModes, "Voice modes", "title"),
            voiceItem(.voiceModes, "Where the LLM works", "modes.llm"),
            voiceItem(.voiceModes, "Your address", "modes.address"),
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
            item(.privacy, "Statistics", "privacy.statistics"),
            item(.privacy, "Count corrections", "privacy.count"),
            item(.privacy, "Languages of apps", "privacy.languages"),
            item(.privacy, "Forget the languages of apps", "privacy.forget-languages"),
            item(.privacy, "Settings file", "privacy.file"),
            item(.privacy, "Back up or move settings", "privacy.backup"),
            item(.privacy, "Feedback", "privacy.feedback"),
            item(.privacy, "A wrong correction?", "privacy.report"),
        ]
        return list
    }
}
