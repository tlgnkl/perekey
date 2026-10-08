// SPDX-License-Identifier: GPL-3.0-or-later

/// The language model file: one binary, little-endian, read in place.
///
/// Layout (docs/classifier.md):
///
///     0   "PKLM"           magic
///     4   u32 version      ModelFormat.version
///     8   u32 header size  bytes before the section table (32)
///     12  u32 section count
///     16  u64 file size
///     24  u64 checksum     FNV-1a 64 of every byte after the section table
///     32  sections         count × (u32 tag, u32 language, u64 offset, u64 length)
///
/// Every section starts on an 8-byte boundary. Integers inside sections are
/// little-endian and naturally aligned, so a reader on a mapped file never
/// copies. Tags and languages are four ASCII bytes packed little-endian,
/// language "ru" is "ru\0\0".
public enum ModelFormat {
    public static let magic: UInt32 = tag("PKLM")
    public static let version: UInt32 = 1
    public static let headerSize = 32
    public static let sectionEntrySize = 24

    /// Builder notes: sources, licences, input hashes. UTF-8 text.
    public static let metaTag = tag("meta")
    /// Character n-gram costs of one language.
    public static let ngramTag = tag("ngrm")
    /// Word forms of one language: fingerprints and frequency ranks.
    public static let dictionaryTag = tag("dict")
    /// Possible word prefixes of one language.
    public static let prefixTag = tag("pfix")
    /// Strings the classifier never switches, case-sensitive.
    public static let keepTag = tag("keep")
    /// Words with a fixed letter case ("МВД", "iPhone") by their folded
    /// fingerprint, and whether Perekey writes them so. Optional: a model
    /// without it corrects no abbreviations.
    public static let casedTag = tag("case")
    /// Words of one language that take "ё" where the "е" spelling is no
    /// other word: the "dict" layout, the value byte marks which "е" become
    /// "ё". Optional, Russian only.
    public static let yoTag = tag("yo")

    /// Four ASCII bytes packed little-endian; shorter strings are zero-padded.
    public static func tag(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        var shift: UInt32 = 0
        for byte in text.utf8.prefix(4) {
            value |= UInt32(byte) << shift
            shift += 8
        }
        return value
    }

    public static func tagString(_ value: UInt32) -> String {
        var scalars: [UInt8] = []
        for shift in stride(from: 0, to: 32, by: 8) {
            let byte = UInt8((value >> UInt32(shift)) & 0xFF)
            if byte != 0 { scalars.append(byte) }
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    /// Checksum of a byte range: FNV-1a 64.
    public static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Case folding the model and the classifier agree on: Latin and Cyrillic
    /// capitals become small letters, everything else stays. `ё` stays `ё`;
    /// the builder adds the `е` spelling of every word with `ё` itself.
    @inlinable
    public static func fold(_ scalar: UInt32) -> UInt32 {
        switch scalar {
        case 0x41...0x5A: return scalar + 32 // A–Z
        case 0x410...0x42F: return scalar + 32 // А–Я
        case 0x401: return 0x451 // Ё
        case 0x404: return 0x454 // Є
        case 0x406: return 0x456 // І
        case 0x407: return 0x457 // Ї
        case 0x490: return 0x491 // Ґ
        default: return scalar
        }
    }

    /// Fingerprint of a word: 64-bit hash of its scalars, folded or not.
    ///
    /// FNV-1a over the little-endian bytes of each scalar, then the MurmurHash3
    /// finaliser so the top bits (the bucket) are as mixed as the bottom ones.
    public struct Fingerprint: Hashable, Sendable {
        public var hash: UInt64 = 0xCBF2_9CE4_8422_2325

        public init() {}

        @inlinable
        public mutating func add(_ scalar: UInt32) {
            var value = scalar
            for _ in 0..<4 {
                hash ^= UInt64(value & 0xFF)
                hash = hash &* 0x0000_0100_0000_01B3
                value >>= 8
            }
        }

        /// The mixed hash. Call once, after the last scalar.
        @inlinable
        public var value: UInt64 {
            var h = hash
            h ^= h >> 33
            h = h &* 0xFF51_AFD7_ED55_8CCD
            h ^= h >> 33
            h = h &* 0xC4CE_B9FE_1A85_EC53
            h ^= h >> 33
            return h
        }

        /// The fingerprint of a string, case-folded or exact.
        public static func of(_ text: some Sequence<Unicode.Scalar>, folded: Bool) -> UInt64 {
            var fingerprint = Fingerprint()
            for scalar in text {
                fingerprint.add(folded ? fold(scalar.value) : scalar.value)
            }
            return fingerprint.value
        }
    }
}
