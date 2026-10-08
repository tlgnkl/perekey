// SPDX-License-Identifier: GPL-3.0-or-later

/// Builds a language model file in memory. Deterministic: the same forms in
/// the same order give the same bytes, whatever the process.
///
/// `perekey-model` feeds it word lists; tests feed it a handful of words.
/// Format: `ModelFormat` and docs/classifier.md.
public struct ModelBuilder: Sendable {
    /// Symbols every alphabet has: 0 ends and pads a word, 1 is any other character.
    public static let boundary: UInt8 = 0
    public static let other: UInt8 = 1
    public static let order = 4
    /// Buckets of the word-form table: 2^16, about 45 forms each for 3 M forms.
    public static let bucketBits = 16

    /// Free text stored in the model: sources, licences, input hashes.
    public var meta = ""
    private var languages: [LanguageBuilder] = []
    private var keep: Set<UInt64> = []

    public init() {}

    /// Starts a language. `alphabet` lists its small letters and joiners (`-`,
    /// `'`) in a fixed order; words with other characters are rejected.
    /// The language must not be added twice.
    public mutating func addLanguage(_ language: String, alphabet: String) {
        precondition(!languages.contains { $0.language == language }, "language \(language) added twice")
        languages.append(LanguageBuilder(language: language, alphabet: alphabet))
    }

    /// Adds one word form.
    /// - Parameters:
    ///   - rank: frequency rank, 0–255, 255 the most frequent; 0 means unknown.
    ///   - weight: how much the form counts in the n-gram statistics; 0 skips them.
    ///   - prefixes: whether its 3- and 4-letter prefixes count as possible.
    /// - Returns: `false` when the form has characters outside the alphabet.
    @discardableResult
    public mutating func addForm(_ form: String, language: String, rank: UInt8, weight: Double,
                                 prefixes: Bool = true) -> Bool
    {
        guard let index = languages.firstIndex(where: { $0.language == language }) else {
            preconditionFailure("unknown language \(language)")
        }
        return languages[index].add(form, rank: rank, weight: weight, prefixes: prefixes)
    }

    /// Adds a string the classifier never switches, case-sensitive.
    public mutating func addKeep(_ text: String) {
        keep.insert(ModelFormat.Fingerprint.of(text.unicodeScalars, folded: false))
    }

    public func build() -> [UInt8] {
        var sections: [(tag: UInt32, language: UInt32, body: [UInt8])] = []
        sections.append((ModelFormat.metaTag, 0, Self.metaSection(meta)))
        for language in languages {
            let code = ModelFormat.tag(language.language)
            sections.append((ModelFormat.ngramTag, code, language.ngramSection()))
            sections.append((ModelFormat.dictionaryTag, code, language.dictionarySection()))
            sections.append((ModelFormat.prefixTag, code, language.prefixSection()))
        }
        sections.append((ModelFormat.keepTag, 0, Self.keepSection(keep)))

        var writer = ByteWriter()
        writer.u32(ModelFormat.magic)
        writer.u32(ModelFormat.version)
        writer.u32(UInt32(ModelFormat.headerSize))
        writer.u32(UInt32(sections.count))
        writer.u64(0) // file size, patched below
        writer.u64(0) // checksum, patched below
        let tableStart = writer.bytes.count
        var offset = tableStart + sections.count * ModelFormat.sectionEntrySize
        offset = (offset + 7) & ~7
        for section in sections {
            writer.u32(section.tag)
            writer.u32(section.language)
            writer.u64(UInt64(offset))
            writer.u64(UInt64(section.body.count))
            offset += (section.body.count + 7) & ~7
        }
        writer.align()
        let payloadStart = writer.bytes.count
        for section in sections {
            writer.bytes.append(contentsOf: section.body)
            writer.align()
        }
        let size = UInt64(writer.bytes.count)
        let checksum = writer.bytes.withUnsafeBytes { buffer in
            ModelFormat.checksum(UnsafeRawBufferPointer(rebasing: buffer[payloadStart...]))
        }
        writer.patch(u64: size, at: 16)
        writer.patch(u64: checksum, at: 24)
        return writer.bytes
    }

    private static func metaSection(_ meta: String) -> [UInt8] {
        var writer = ByteWriter()
        let utf8 = Array(meta.utf8)
        writer.u32(UInt32(utf8.count))
        writer.u32(0)
        writer.bytes.append(contentsOf: utf8)
        return writer.bytes
    }

    private static func keepSection(_ keep: Set<UInt64>) -> [UInt8] {
        var writer = ByteWriter()
        writer.u32(UInt32(keep.count))
        writer.u32(0)
        for hash in keep.sorted() { writer.u64(hash) }
        return writer.bytes
    }
}

/// The statistics of one language while the model is being built.
struct LanguageBuilder: Sendable {
    let language: String
    let alphabet: [UInt32]
    private var symbols: [UInt32: UInt8]
    private var counts: [Double]
    private var ranks: [UInt64: UInt8] = [:]
    private var prefixes3: [UInt64]
    private var prefixes4: [UInt64]

    var alphabetSize: Int { alphabet.count + 2 }

    init(language: String, alphabet: String) {
        self.language = language
        self.alphabet = alphabet.unicodeScalars.map { ModelFormat.fold($0.value) }
        var symbols: [UInt32: UInt8] = [:]
        for (index, scalar) in self.alphabet.enumerated() {
            precondition(symbols[scalar] == nil, "alphabet repeats \(Unicode.Scalar(scalar)!)")
            symbols[scalar] = UInt8(index + 2)
        }
        self.symbols = symbols
        let size = alphabet.unicodeScalars.count + 2
        counts = Array(repeating: 0, count: size * size * size * size)
        prefixes3 = Array(repeating: 0, count: (size * size * size + 63) / 64)
        prefixes4 = Array(repeating: 0, count: (size * size * size * size + 63) / 64)
    }

    mutating func add(_ form: String, rank: UInt8, weight: Double, prefixes: Bool) -> Bool {
        var word: [UInt8] = []
        var fingerprint = ModelFormat.Fingerprint()
        var hasYo = false
        for scalar in form.unicodeScalars {
            let folded = ModelFormat.fold(scalar.value)
            guard let symbol = symbols[folded] else { return false }
            word.append(symbol)
            fingerprint.add(folded)
            if folded == 0x451 { hasYo = true }
        }
        guard !word.isEmpty else { return false }
        addSymbols(word, fingerprint: fingerprint.value, rank: rank, weight: weight, prefixes: prefixes)

        // The same word spelt with "е" instead of "ё", as most people type it.
        if hasYo, let e = symbols[0x435], let yo = symbols[0x451] {
            var plain = ModelFormat.Fingerprint()
            for scalar in form.unicodeScalars {
                let folded = ModelFormat.fold(scalar.value)
                plain.add(folded == 0x451 ? 0x435 : folded)
            }
            let spelled = word.map { $0 == yo ? e : $0 }
            addSymbols(spelled, fingerprint: plain.value, rank: rank, weight: weight, prefixes: prefixes)
        }
        return true
    }

    private mutating func addSymbols(_ word: [UInt8], fingerprint: UInt64, rank: UInt8, weight: Double,
                                     prefixes: Bool)
    {
        let a = alphabetSize
        if weight > 0 {
            var h0 = 0, h1 = 0, h2 = 0
            for symbol in word {
                counts[((h0 * a + h1) * a + h2) * a + Int(symbol)] += weight
                h0 = h1; h1 = h2; h2 = Int(symbol)
            }
            counts[((h0 * a + h1) * a + h2) * a] += weight // the end of the word
        }
        if let known = ranks[fingerprint] {
            ranks[fingerprint] = max(known, rank)
        } else {
            ranks[fingerprint] = rank
        }
        if prefixes {
            if word.count >= 3 {
                let index = (Int(word[0]) * a + Int(word[1])) * a + Int(word[2])
                prefixes3[index / 64] |= 1 << UInt64(index % 64)
            }
            if word.count >= 4 {
                let index = ((Int(word[0]) * a + Int(word[1])) * a + Int(word[2])) * a + Int(word[3])
                prefixes4[index / 64] |= 1 << UInt64(index % 64)
            }
        }
    }

    /// Costs in eighths of a bit, `-8·log₂P(c | h0 h1 h2)`, Witten–Bell
    /// interpolated down to unigrams, so the classifier reads one table.
    func ngramSection() -> [UInt8] {
        let a = alphabetSize
        let a2 = a * a, a3 = a2 * a
        // Lower orders are marginals: every character has a full context
        // because words are padded with three boundaries.
        var counts3 = [Double](repeating: 0, count: a3)
        var counts2 = [Double](repeating: 0, count: a2)
        var counts1 = [Double](repeating: 0, count: a)
        for index in counts.indices where counts[index] != 0 {
            counts3[index % a3] += counts[index]
            counts2[index % a2] += counts[index]
            counts1[index % a] += counts[index]
        }
        let total = counts1.reduce(0, +)
        var p1 = [Double](repeating: 0, count: a)
        for c in 0..<a { p1[c] = (counts1[c] + 0.5) / (total + 0.5 * Double(a)) }

        func interpolate(_ higher: [Double], _ lower: [Double], contexts: Int) -> [Double] {
            var result = [Double](repeating: 0, count: contexts * a)
            for h in 0..<contexts {
                var n = 0.0
                var types = 0.0
                for c in 0..<a where higher[h * a + c] > 0 {
                    n += higher[h * a + c]
                    types += 1
                }
                let lowerBase = (h % (contexts / a)) * a
                for c in 0..<a {
                    let back = lower[lowerBase + c]
                    result[h * a + c] = n > 0 ? (higher[h * a + c] + types * back) / (n + types) : back
                }
            }
            return result
        }
        let p2 = interpolate(counts2, p1, contexts: a)
        let p3 = interpolate(counts3, p2, contexts: a2)
        let p4 = interpolate(counts, p3, contexts: a3)

        var writer = ByteWriter()
        writer.u32(UInt32(ModelBuilder.order))
        writer.u32(UInt32(a))
        writer.u32(UInt32(alphabet.count))
        writer.u32(0)
        for (index, scalar) in alphabet.enumerated().sorted(by: { $0.element < $1.element }) {
            writer.u32(scalar)
            writer.u32(UInt32(index + 2))
        }
        writer.bytes.reserveCapacity(writer.bytes.count + p4.count)
        for p in p4 {
            let cost = (-p.log2() * 8).rounded()
            writer.bytes.append(UInt8(min(255, max(0, cost))))
        }
        return writer.bytes
    }

    func dictionarySection() -> [UInt8] {
        let bits = ModelBuilder.bucketBits
        // Grouped by bucket (the top bits of the hash), ordered by the 32-bit
        // fingerprint (the low bits) within a bucket: the reader's search order.
        func order(_ hash: UInt64) -> (Int, UInt32) {
            (Int(hash >> UInt64(64 - bits)), UInt32(truncatingIfNeeded: hash))
        }
        let sorted = ranks.sorted { order($0.key) < order($1.key) }
        var writer = ByteWriter()
        writer.u32(UInt32(bits))
        writer.u32(UInt32(sorted.count))
        writer.u64(0)
        var bucket = 0
        writer.u32(0)
        for (index, entry) in sorted.enumerated() {
            let target = Int(entry.key >> UInt64(64 - bits))
            while bucket < target {
                writer.u32(UInt32(index))
                bucket += 1
            }
        }
        while bucket < (1 << bits) {
            writer.u32(UInt32(sorted.count))
            bucket += 1
        }
        for entry in sorted { writer.u32(UInt32(truncatingIfNeeded: entry.key)) }
        writer.align()
        for entry in sorted { writer.bytes.append(entry.value) }
        return writer.bytes
    }

    func prefixSection() -> [UInt8] {
        var writer = ByteWriter()
        writer.u32(UInt32(alphabetSize))
        writer.u32(0)
        writer.u64(UInt64(prefixes3.count))
        writer.u64(UInt64(prefixes4.count))
        for word in prefixes3 { writer.u64(word) }
        for word in prefixes4 { writer.u64(word) }
        return writer.bytes
    }
}

/// Little-endian byte output.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }

    mutating func patch(u64 value: UInt64, at offset: Int) {
        for (index, shift) in stride(from: 0, to: 64, by: 8).enumerated() {
            bytes[offset + index] = UInt8((value >> UInt64(shift)) & 0xFF)
        }
    }

    mutating func align() {
        while bytes.count % 8 != 0 { bytes.append(0) }
    }
}

extension Double {
    func log2() -> Double {
        // Foundation-free log2: the standard library has no log, but the
        // significand and exponent give it to a precision well beyond an
        // eighth of a bit after a short series.
        precondition(self > 0)
        let exponent = Double(self.exponent)
        let m = self.significand // in [1, 2)
        // log2(m) = ln(m)/ln(2); ln(m) via atanh series on (m-1)/(m+1).
        let z = (m - 1) / (m + 1)
        let z2 = z * z
        var term = z
        var sum = 0.0
        var k = 1.0
        while k < 60 {
            sum += term / k
            term *= z2
            k += 2
            if term < 1e-18 { break }
        }
        return exponent + 2 * sum / 0.693_147_180_559_945_3
    }
}
