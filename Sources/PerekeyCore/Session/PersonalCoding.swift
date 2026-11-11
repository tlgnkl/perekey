// SPDX-License-Identifier: GPL-3.0-or-later

// The personal lexicon in the session format (`RecordedEvent`,
// `MachineSnapshot`, `OutputDigest`): fingerprints and the key as hex, no
// text. A session file holds typed text anyway and is written only by the
// recording build (`PEREKEY_RECORD`); the key is there so that a replay
// looks words up as the recorded machine did. The recorder of the app must
// not write the real key: docs/classifier.md, «Личный словарь», «Что
// требуется от хранилища».
//
// A decoding error names the place and the rule, never the value: a file
// that is not a session may hold anything, and the error ends up in a log.

/// Hex digits of a 64-bit value: JSON numbers lose such values in many readers.
private let hexDigits = 16
/// Hex digits of the key: two 64-bit halves.
private let keyDigits = 2 * hexDigits

private func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: hexDigits - digits.count) + digits
}

private func value(_ text: String, at path: [any CodingKey]) throws -> UInt64 {
    guard text.utf8.count == hexDigits, let value = UInt64(text, radix: 16) else {
        throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "not \(hexDigits) hex digits"))
    }
    return value
}

extension PersonalLexicon: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, words, starts, languages, generation, minLetters, maxLetters
    }

    /// `.off` is an empty object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let keyText = try container.decodeIfPresent(String.self, forKey: .key) else {
            self = .off
            return
        }
        let path = container.codingPath + [CodingKeys.key]
        guard keyText.utf8.count == keyDigits else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "a key is \(keyDigits) hex digits"))
        }
        let key = try PersonalKey(k0: value(String(keyText.prefix(hexDigits)), at: path),
                                  k1: value(String(keyText.suffix(hexDigits)), at: path))
        guard !key.isZero else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "a key is not all zero"))
        }
        var options = PersonalOptions()
        options.minLetters = try container.decode(Int.self, forKey: .minLetters)
        options.maxLetters = try container.decode(Int.self, forKey: .maxLetters)
        let languages = try container.decodeIfPresent([String].self, forKey: .languages)?.map { text -> LanguageCode in
            guard let code = LanguageCode(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "not a language code"))
            }
            return code
        }
        self.init(key: key, words: try container.decode([String].self, forKey: .words).map { try value($0, at: path) },
                  starts: try container.decode([String].self, forKey: .starts).map { try value($0, at: path) },
                  languages: languages, generation: try container.decode(UInt32.self, forKey: .generation),
                  options: options)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let key else { return }
        try container.encode(hex(key.k0) + hex(key.k1), forKey: .key)
        try container.encode(words.map(hex), forKey: .words)
        try container.encode(starts.map(hex), forKey: .starts)
        try container.encodeIfPresent(languages?.map(\.text), forKey: .languages)
        try container.encode(generation, forKey: .generation)
        try container.encode(minLetters, forKey: .minLetters)
        try container.encode(maxLetters, forKey: .maxLetters)
    }
}

extension PersonalObservation: Codable {
    private enum CodingKeys: String, CodingKey {
        case word, start3, start4, language
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = container.codingPath
        guard let language = LanguageCode(try container.decode(String.self, forKey: .language)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path + [CodingKeys.language],
                                                    debugDescription: "not a language code"))
        }
        try self.init(word: value(container.decode(String.self, forKey: .word), at: path),
                      start3: container.decodeIfPresent(String.self, forKey: .start3).map { try value($0, at: path) },
                      start4: container.decodeIfPresent(String.self, forKey: .start4).map { try value($0, at: path) },
                      language: language)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hex(word), forKey: .word)
        try container.encodeIfPresent(start3.map(hex), forKey: .start3)
        try container.encodeIfPresent(start4.map(hex), forKey: .start4)
        try container.encode(language.text, forKey: .language)
    }
}
