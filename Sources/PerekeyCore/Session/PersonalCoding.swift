// SPDX-License-Identifier: GPL-3.0-or-later

// The personal lexicon in the session format (`RecordedEvent`,
// `MachineSnapshot`, `OutputDigest`): fingerprints and the key as hex, no
// text. A session file holds typed text anyway and is written only by the
// recording build (`PEREKEY_RECORD`); the key is there so that a replay
// looks words up as the recorded machine did.

/// A 64-bit value as 16 hex digits: JSON numbers lose such values in many readers.
private func hex(_ value: UInt64) -> String {
    let digits = String(value, radix: 16)
    return String(repeating: "0", count: 16 - digits.count) + digits
}

private func value(_ text: String, at path: [any CodingKey]) throws -> UInt64 {
    guard text.utf8.count == 16, let value = UInt64(text, radix: 16) else {
        throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "not 16 hex digits: \(text)"))
    }
    return value
}

extension PersonalLexicon: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, words, starts, generation, minLetters, maxLetters
    }

    /// `.off` is an empty object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let keyText = try container.decodeIfPresent(String.self, forKey: .key) else {
            self = .off
            return
        }
        guard keyText.utf8.count == 32 else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath + [CodingKeys.key],
                                                    debugDescription: "a key is 32 hex digits"))
        }
        let path = container.codingPath
        let key = try PersonalKey(k0: value(String(keyText.prefix(16)), at: path),
                                  k1: value(String(keyText.suffix(16)), at: path))
        var options = PersonalOptions()
        options.minLetters = try container.decode(Int.self, forKey: .minLetters)
        options.maxLetters = try container.decode(Int.self, forKey: .maxLetters)
        self.init(key: key, words: try container.decode([String].self, forKey: .words).map { try value($0, at: path) },
                  starts: try container.decode([String].self, forKey: .starts).map { try value($0, at: path) },
                  generation: try container.decode(UInt32.self, forKey: .generation), options: options)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let key else { return }
        try container.encode(hex(key.k0) + hex(key.k1), forKey: .key)
        try container.encode(words.map(hex), forKey: .words)
        try container.encode(starts.map(hex), forKey: .starts)
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
        try self.init(word: value(container.decode(String.self, forKey: .word), at: path),
                      start3: value(container.decode(String.self, forKey: .start3), at: path),
                      start4: container.decodeIfPresent(String.self, forKey: .start4).map { try value($0, at: path) },
                      language: container.decode(String.self, forKey: .language))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hex(word), forKey: .word)
        try container.encode(hex(start3), forKey: .start3)
        try container.encodeIfPresent(start4.map(hex), forKey: .start4)
        try container.encode(language, forKey: .language)
    }
}

