// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// The settings presets a case names in `env.settings` (docs/eval.md,
/// «Настройки»). Every field is spelled out, not taken from `Settings()`:
/// a test compares `default` with the core's defaults field by field, so a
/// change of the defaults in the core shows up as a red test here.
public enum EvalSettings {
    public static let defaultPreset = "default"
    public static let names = ["default", "all", "layout-only", "off"]

    public static func preset(_ name: String) -> Settings? {
        switch name {
        case "default":
            // As released: automatic switching, typos, double capitals, phrase retype.
            settings(autoswitch: true, typos: true,
                     corrections: TextCorrections(phraseRetype: true, doubleCapitals: true, capsLock: false,
                                                  abbreviations: false, yo: false, hyphen: false))
        case "all":
            settings(autoswitch: true, typos: true,
                     corrections: TextCorrections(phraseRetype: true, doubleCapitals: true, capsLock: true,
                                                  abbreviations: true, yo: true, hyphen: true))
        case "layout-only":
            settings(autoswitch: true, typos: false, corrections: none)
        case "off":
            // Nothing by itself; the shortcuts still work.
            settings(autoswitch: false, typos: false, corrections: none)
        default:
            nil
        }
    }

    /// The preset with the case's own words added.
    public static func settings(for env: Env) throws -> Settings {
        guard var settings = preset(env.effectiveSettings) else {
            throw EvalError.input("unknown settings preset \(env.effectiveSettings)")
        }
        for word in env.exceptions ?? [] { settings.exceptions.insert(word) }
        for (key, spelling) in env.alwaysFix ?? [:] { settings.alwaysFix[key] = spelling }
        return settings
    }

    private static let none = TextCorrections(phraseRetype: false, doubleCapitals: false, capsLock: false,
                                              abbreviations: false, yo: false, hyphen: false)

    private static func settings(autoswitch: Bool, typos: Bool, corrections: TextCorrections) -> Settings {
        Settings(hotkeys: HotkeyPreset.standard.hotkeys, autoswitch: autoswitch, fenceTimeout: 0.3, postTimeout: 2,
                 exceptions: [], appExceptions: [:], alwaysFix: [:], learnFromUndos: true,
                 corrections: corrections, typoCorrection: typos, voice: nil)
    }
}
