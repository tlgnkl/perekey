// SPDX-License-Identifier: GPL-3.0-or-later

/// A language model file, read in place from a raw buffer.
///
/// The buffer must stay alive and unchanged as long as the model is used:
/// `owner` holds whatever keeps it mapped (`ModelFile` for a file on disk, an
/// array for a model built in memory). Loading validates the header, the
/// checksum and every section bound, so lookups never range-check again.
public struct LanguageModel: @unchecked Sendable {
    public enum Error: Swift.Error, Hashable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt32)
        case badChecksum
        case badSection(String)
        case languageIncomplete(String)
    }

    public struct Language: @unchecked Sendable {
        public let code: String
        let alphabetSize: Int
        /// Symbol of every scalar below `symbolTableSize`, `ModelBuilder.other` elsewhere.
        let symbols: [UInt8]
        /// `-8·log₂P(c | h0 h1 h2)`, index `((h0·A + h1)·A + h2)·A + c`.
        let costs: UnsafePointer<UInt8>
        let bucketBits: Int
        let bucketOffsets: UnsafePointer<UInt32>
        let fingerprints: UnsafePointer<UInt32>
        let ranks: UnsafePointer<UInt8>
        let prefixes3: UnsafePointer<UInt64>
        let prefixes4: UnsafePointer<UInt64>
    }

    static let symbolTableSize = 0x500

    public let bytes: UnsafeRawBufferPointer
    private let owner: AnyObject?
    public let meta: String
    public let languages: [Language]
    private let keepHashes: UnsafePointer<UInt64>
    private let keepCount: Int

    /// Reads a model from `bytes`. `owner` is retained for the life of the model.
    public init(bytes: UnsafeRawBufferPointer, owner: AnyObject?) throws {
        self.bytes = bytes
        self.owner = owner
        var reader = ByteReader(bytes)
        guard bytes.count >= ModelFormat.headerSize else { throw Error.truncated }
        guard reader.u32() == ModelFormat.magic else { throw Error.badMagic }
        let version = reader.u32()
        guard version == ModelFormat.version else { throw Error.unsupportedVersion(version) }
        let headerSize = Int(reader.u32())
        let sectionCount = Int(reader.u32())
        let size = reader.u64()
        let checksum = reader.u64()
        guard headerSize == ModelFormat.headerSize, size == UInt64(bytes.count) else { throw Error.truncated }
        let tableEnd = headerSize + sectionCount * ModelFormat.sectionEntrySize
        guard tableEnd <= bytes.count else { throw Error.truncated }
        let payloadStart = (tableEnd + 7) & ~7
        guard payloadStart <= bytes.count,
              ModelFormat.checksum(UnsafeRawBufferPointer(rebasing: bytes[payloadStart...])) == checksum
        else { throw Error.badChecksum }

        var meta = ""
        var keep: (UnsafePointer<UInt64>, Int)?
        var partial: [String: (ngram: UnsafeRawBufferPointer?, dict: UnsafeRawBufferPointer?,
                               prefix: UnsafeRawBufferPointer?)] = [:]
        var order: [String] = []
        for _ in 0..<sectionCount {
            let tag = reader.u32()
            let language = ModelFormat.tagString(reader.u32())
            let offset = reader.u64()
            let length = reader.u64()
            guard offset % 8 == 0, offset >= UInt64(payloadStart), length <= UInt64(bytes.count),
                  offset <= UInt64(bytes.count) - length
            else { throw Error.badSection(ModelFormat.tagString(tag)) }
            let body = UnsafeRawBufferPointer(rebasing: bytes[Int(offset)..<Int(offset + length)])
            switch tag {
            case ModelFormat.metaTag:
                guard body.count >= 8 else { throw Error.badSection("meta") }
                var section = ByteReader(body)
                let count = Int(section.u32())
                guard count + 8 <= body.count else { throw Error.badSection("meta") }
                meta = String(decoding: UnsafeRawBufferPointer(rebasing: body[8..<8 + count]), as: UTF8.self)
            case ModelFormat.keepTag:
                guard body.count >= 8 else { throw Error.badSection("keep") }
                var section = ByteReader(body)
                let count = Int(section.u32())
                guard 8 + count * 8 <= body.count else { throw Error.badSection("keep") }
                keep = (body.baseAddress!.advanced(by: 8).assumingMemoryBound(to: UInt64.self), count)
            case ModelFormat.ngramTag, ModelFormat.dictionaryTag, ModelFormat.prefixTag:
                if partial[language] == nil {
                    partial[language] = (nil, nil, nil)
                    order.append(language)
                }
                if tag == ModelFormat.ngramTag { partial[language]!.ngram = body }
                if tag == ModelFormat.dictionaryTag { partial[language]!.dict = body }
                if tag == ModelFormat.prefixTag { partial[language]!.prefix = body }
            default:
                continue // unknown sections are for newer readers
            }
        }
        self.meta = meta
        guard let keep else { throw Error.badSection("keep") }
        keepHashes = keep.0
        keepCount = keep.1
        languages = try order.map { code in
            let parts = partial[code]!
            guard let ngram = parts.ngram, let dict = parts.dict, let prefix = parts.prefix else {
                throw Error.languageIncomplete(code)
            }
            return try Language(code: code, ngram: ngram, dictionary: dict, prefix: prefix)
        }
    }

    /// Reads a model from an array, which the model keeps alive.
    public init(bytes array: [UInt8]) throws {
        let box = ArrayBox(array)
        try self.init(bytes: box.buffer, owner: box)
    }

    public func language(_ code: String) -> Language? {
        languages.first { $0.code == code }
    }

    /// Whether this exact string is on the never-switch list.
    public func isKept(_ fingerprint: UInt64) -> Bool {
        var low = 0
        var high = keepCount
        while low < high {
            let mid = (low + high) / 2
            let value = keepHashes[mid]
            if value == fingerprint { return true }
            if value < fingerprint { low = mid + 1 } else { high = mid }
        }
        return false
    }
}

extension LanguageModel.Language {
    init(code: String, ngram: UnsafeRawBufferPointer, dictionary: UnsafeRawBufferPointer,
         prefix: UnsafeRawBufferPointer) throws
    {
        self.code = code
        var reader = ByteReader(ngram)
        guard ngram.count >= 16 else { throw LanguageModel.Error.badSection("ngrm") }
        let order = Int(reader.u32())
        let a = Int(reader.u32())
        let mapCount = Int(reader.u32())
        _ = reader.u32()
        guard order == ModelBuilder.order, a >= 3, a <= 64, mapCount == a - 2,
              16 + mapCount * 8 + a * a * a * a <= ngram.count
        else { throw LanguageModel.Error.badSection("ngrm") }
        alphabetSize = a
        var symbols = [UInt8](repeating: ModelBuilder.other, count: LanguageModel.symbolTableSize)
        for _ in 0..<mapCount {
            let scalar = Int(reader.u32())
            let symbol = reader.u32()
            guard scalar < symbols.count, symbol >= 2, symbol < a else {
                throw LanguageModel.Error.badSection("ngrm")
            }
            symbols[scalar] = UInt8(symbol)
        }
        self.symbols = symbols
        costs = ngram.baseAddress!.advanced(by: 16 + mapCount * 8).assumingMemoryBound(to: UInt8.self)

        reader = ByteReader(dictionary)
        guard dictionary.count >= 16 else { throw LanguageModel.Error.badSection("dict") }
        bucketBits = Int(reader.u32())
        let count = Int(reader.u32())
        _ = reader.u64()
        guard bucketBits >= 1, bucketBits <= 24 else { throw LanguageModel.Error.badSection("dict") }
        let offsetsStart = 16
        let fingerprintsStart = offsetsStart + ((1 << bucketBits) + 1) * 4
        let ranksStart = (fingerprintsStart + count * 4 + 7) & ~7
        guard ranksStart + count <= dictionary.count else { throw LanguageModel.Error.badSection("dict") }
        bucketOffsets = dictionary.baseAddress!.advanced(by: offsetsStart).assumingMemoryBound(to: UInt32.self)
        fingerprints = dictionary.baseAddress!.advanced(by: fingerprintsStart).assumingMemoryBound(to: UInt32.self)
        ranks = dictionary.baseAddress!.advanced(by: ranksStart).assumingMemoryBound(to: UInt8.self)
        for bucket in 0..<(1 << bucketBits) {
            guard bucketOffsets[bucket] <= bucketOffsets[bucket + 1], Int(bucketOffsets[bucket + 1]) <= count else {
                throw LanguageModel.Error.badSection("dict")
            }
        }

        reader = ByteReader(prefix)
        guard prefix.count >= 24, Int(reader.u32()) == a else { throw LanguageModel.Error.badSection("pfix") }
        _ = reader.u32()
        let words3 = Int(reader.u64())
        let words4 = Int(reader.u64())
        guard words3 == (a * a * a + 63) / 64, words4 == (a * a * a * a + 63) / 64,
              24 + (words3 + words4) * 8 <= prefix.count
        else { throw LanguageModel.Error.badSection("pfix") }
        prefixes3 = prefix.baseAddress!.advanced(by: 24).assumingMemoryBound(to: UInt64.self)
        prefixes4 = prefixes3.advanced(by: words3)
    }

    /// The symbol of a scalar: its letter, or `other`.
    @inline(__always)
    public func symbol(_ scalar: UInt32) -> UInt8 {
        let folded = ModelFormat.fold(scalar)
        return folded < UInt32(symbols.count) ? symbols[Int(folded)] : ModelBuilder.other
    }

    /// Whether the scalar is a letter or joiner of this language.
    public func isLetter(_ scalar: UInt32) -> Bool {
        symbol(scalar) >= 2
    }

    /// The cost in bits of a word given as symbols, boundaries included:
    /// `-log₂ P(word)` under the 4-gram model.
    public func cost(_ word: UnsafeBufferPointer<UInt8>) -> Double {
        let a = alphabetSize
        var h0 = 0, h1 = 0, h2 = 0
        var total = 0
        for symbol in word {
            total += Int(costs[((h0 * a + h1) * a + h2) * a + Int(symbol)])
            h0 = h1; h1 = h2; h2 = Int(symbol)
        }
        total += Int(costs[((h0 * a + h1) * a + h2) * a])
        return Double(total) / 8
    }

    /// The frequency rank of a word form by its folded fingerprint, `nil` if unknown.
    public func rank(of fingerprint: UInt64) -> UInt8? {
        let bucket = Int(fingerprint >> UInt64(64 - bucketBits))
        let wanted = UInt32(truncatingIfNeeded: fingerprint)
        var low = Int(bucketOffsets[bucket])
        var high = Int(bucketOffsets[bucket + 1])
        while low < high {
            let mid = (low + high) / 2
            let value = fingerprints[mid]
            if value == wanted { return ranks[mid] }
            if value < wanted { low = mid + 1 } else { high = mid }
        }
        return nil
    }

    /// Whether some word of the language starts with these 3 or 4 symbols.
    func isPossiblePrefix(_ word: UnsafeBufferPointer<UInt8>) -> Bool {
        let a = alphabetSize
        switch word.count {
        case 3:
            let index = (Int(word[0]) * a + Int(word[1])) * a + Int(word[2])
            return prefixes3[index / 64] & (1 << UInt64(index % 64)) != 0
        case 4:
            let index = ((Int(word[0]) * a + Int(word[1])) * a + Int(word[2])) * a + Int(word[3])
            return prefixes4[index / 64] & (1 << UInt64(index % 64)) != 0
        default:
            return true
        }
    }
}

/// Keeps an array alive and pinned while a model reads it.
final class ArrayBox: @unchecked Sendable {
    let storage: UnsafeMutableRawBufferPointer

    init(_ array: [UInt8]) {
        storage = UnsafeMutableRawBufferPointer.allocate(byteCount: max(array.count, 1), alignment: 8)
        array.withUnsafeBytes { storage.copyMemory(from: $0) }
    }

    var buffer: UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: storage.prefix(storage.count)) }

    deinit { storage.deallocate() }
}

/// Little-endian reads with no alignment requirement.
struct ByteReader {
    let bytes: UnsafeRawBufferPointer
    var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func u32() -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << UInt32(index * 8) }
        offset += 4
        return value
    }

    mutating func u64() -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        offset += 8
        return value
    }
}
