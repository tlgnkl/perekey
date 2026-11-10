// SPDX-License-Identifier: GPL-3.0-or-later

/// The language to tell the speech model before a dictation. A wrong hint
/// makes the model write the speech in the wrong language; with none it finds
/// the language itself, as it always did. So the hint exists only when the
/// signs agree.
public enum DictationLanguageHint {
    /// - Parameters:
    ///   - appLanguage: the language most typed in the app the text goes to,
    ///     once there is enough to say (`LanguageStats.dominantLanguage`).
    ///   - layoutLanguage: the language of the layout selected now.
    ///   - previous: the language of the last dictation into this app, if
    ///     the app has had one in this run and its language was clear.
    /// - Returns: the language when the app's is known, the layout is of the
    ///   same language, and the last dictation into the app did not go the
    ///   other way; else nil.
    public static func hint(appLanguage: String?, layoutLanguage: String?, previous: String?) -> String? {
        guard let appLanguage, appLanguage == layoutLanguage else { return nil }
        if let previous, previous != appLanguage { return nil }
        return appLanguage
    }
}

/// What the language hint reads outside the voice controller for a dictation
/// into one app: the language of the app and of the layout now, and a check
/// of what language a text is written in.
public struct DictationLanguageSigns: Sendable {
    public var appLanguage: String?
    public var layoutLanguage: String?
    public var dominant: @Sendable (String) -> String?

    public init(appLanguage: String?, layoutLanguage: String?, dominant: @escaping @Sendable (String) -> String?) {
        self.appLanguage = appLanguage
        self.layoutLanguage = layoutLanguage
        self.dominant = dominant
    }
}

/// A hint with the means to check the text it gave: the model, told the
/// language, may still write another or make the speech up.
public struct LanguageHint: Sendable {
    /// The code the engine is told ("ru").
    public let language: String
    /// The language of a text, nil when it has no clear one
    /// (`DictationLanguage.dominant`).
    public let dominant: @Sendable (String) -> String?

    public init(language: String, dominant: @escaping @Sendable (String) -> String?) {
        self.language = language
        self.dominant = dominant
    }
}

/// The language of the last dictation into each app, in memory only: the
/// hint reads it, nothing writes it down. Bounded, the oldest app goes first.
public struct LastDictationLanguages: Sendable, Equatable {
    public let limit: Int
    private var order: [String] = []
    private var languages: [String: String] = [:]

    public init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    public func language(app: String) -> String? {
        languages[app]
    }

    /// `language` nil (the text had no clear one) makes the app forgotten.
    public mutating func record(language: String?, app: String) {
        order.removeAll { $0 == app }
        guard let language else {
            languages[app] = nil
            return
        }
        languages[app] = language
        order.append(app)
        while order.count > limit {
            languages[order.removeFirst()] = nil
        }
    }
}
