// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

/// The "pair" section of the model: the lift of a word after another
/// (docs/classifier.md, «Пары слов»).
@Suite struct PairSectionTests {
    private func fingerprint(_ text: String) -> UInt64 {
        ModelFormat.Fingerprint.of(text.unicodeScalars, folded: true)
    }

    /// A Russian model with a few pairs.
    private func model(pairs: [(String, String, UInt8)], reversed: Bool = false) throws -> (LanguageModel, [UInt8]) {
        var builder = ModelBuilder()
        builder.addLanguage("ru", alphabet: ModelFilesTests.russianAlphabet)
        for word in ["привет", "мир", "как", "дела"] { builder.addForm(word, language: "ru", rank: 200, weight: 100) }
        builder.addKeep("iPhone")
        for (previous, word, lift) in reversed ? pairs.reversed() : pairs {
            builder.addPair(previous: previous.isEmpty ? ModelFormat.sentenceStart : fingerprint(previous),
                            word: fingerprint(word), lift: lift, language: "ru")
        }
        let bytes = builder.build()
        return (try LanguageModel(bytes: bytes), bytes)
    }

    // MARK: The key

    @Test func theKeyDependsOnTheOrderAndHasAGoldenValue() {
        let a = fingerprint("привет"), b = fingerprint("мир")
        #expect(ModelFormat.pairKey(previous: a, word: b) != ModelFormat.pairKey(previous: b, word: a))
        #expect(ModelFormat.pairKey(previous: a, word: b) == ModelFormat.pairKey(previous: a, word: b))
        // Moving this value moves every pair of every shipped model: change it with the format only.
        #expect(ModelFormat.pairKey(previous: 1, word: 2) == 0x0083_950B_668A_424A)
    }

    @Test func theStartOfASentenceIsNoWord() {
        #expect(ModelFormat.sentenceStart == ModelFormat.Fingerprint.of("\u{2029}".unicodeScalars, folded: false))
        #expect(ModelFormat.sentenceStart == 0xEC95_9712_BB16_58DC)
        // No word of any alphabet holds U+2029, so no word has this fingerprint.
        #expect(ModelFormat.sentenceStart != fingerprint("привет"))
        #expect(ModelFormat.pairKey(previous: ModelFormat.sentenceStart, word: fingerprint("привет"))
            != ModelFormat.pairKey(previous: fingerprint("привет"), word: ModelFormat.sentenceStart))
    }

    // MARK: The lift

    @Test func theLiftIsTheDiscountedConditionalOverTheMarginalInEighthsOfABit() throws {
        // P(w | p) = (10 − 0.75) / 100, P(w) = 50 / 10000: 9.25 / 0.5 = 18.5 times, 4.2095 bits.
        let lift = try #require(ModelBuilder.pairLift(count: 10, previous: 100, word: 50, total: 10_000))
        #expect(lift == 34) // 8 · 4.2095 = 33.7
        // A pair as likely as chance has lift 0, a rarer one a negative lift.
        #expect(ModelBuilder.pairLift(count: 5, previous: 100, word: 5000, total: 100_000)! < 0)
        // The discount takes a pair seen once to nothing at 1: count 1 − 0.75 > 0 still counts.
        #expect(ModelBuilder.pairLift(count: 1, previous: 100, word: 50, total: 10_000, discount: 1) == nil)
        #expect(ModelBuilder.pairLift(count: 3, previous: 0, word: 50, total: 10_000) == nil)
    }

    @Test func theLiftDoesNotUseTheSystemLog() throws {
        // The series of `Double.log2()` agrees with the exact value to far less than an eighth of a bit.
        for (count, previous, word, total) in [(3, 7, 90, 1_000_000), (400, 5000, 12, 60_000_000), (9, 9, 9, 100)] {
            let lift = try #require(ModelBuilder.pairLift(count: count, previous: previous, word: word, total: total))
            let exact = 8 * (((Double(count) - 0.75) / Double(previous)) / (Double(word) / Double(total))).log2()
            #expect(abs(Double(lift) - exact) <= 0.5 + 1e-9)
        }
    }

    // MARK: Writing and reading

    @Test func theSectionReturnsTheLiftOfEveryPairAndNilForTheRest() throws {
        let (model, _) = try model(pairs: [("привет", "мир", 40), ("как", "дела", 255), ("", "привет", 9)])
        let ru = try #require(model.language("ru"))
        #expect(ru.hasPairTable)
        #expect(ru.pairLift(previous: fingerprint("привет"), word: fingerprint("мир")) == 40)
        #expect(ru.pairLift(previous: fingerprint("как"), word: fingerprint("дела")) == 255)
        #expect(ru.pairLift(previous: ModelFormat.sentenceStart, word: fingerprint("привет")) == 9)
        // Order matters; a pair that is not there is "no evidence", not "impossible".
        #expect(ru.pairLift(previous: fingerprint("мир"), word: fingerprint("привет")) == nil)
        #expect(ru.pairLift(previous: fingerprint("привет"), word: fingerprint("дела")) == nil)
    }

    @Test func aModelWithoutPairsReadsAsBeforeAndKnowsNoPair() throws {
        let (model, _) = try model(pairs: [])
        let ru = try #require(model.language("ru"))
        #expect(!ru.hasPairTable)
        #expect(ru.pairLift(previous: fingerprint("привет"), word: fingerprint("мир")) == nil)
        #expect(ru.rank(of: fingerprint("привет")) == 200)
    }

    @Test func theSectionIsOptionalAndAnOlderReaderSkipsIt() throws {
        // A reader that does not know the tag gets the same dictionary: the
        // section sits behind the ones it knows and its tag falls to `default`.
        let (withPairs, _) = try model(pairs: [("привет", "мир", 40)])
        let (without, _) = try model(pairs: [])
        let a = try #require(withPairs.language("ru")), b = try #require(without.language("ru"))
        for word in ["привет", "мир", "как", "дела", "нет"] {
            #expect(a.rank(of: fingerprint(word)) == b.rank(of: fingerprint(word)))
        }
    }

    @Test func aPairAddedTwiceKeepsTheLargerLift() throws {
        let (model, _) = try model(pairs: [("привет", "мир", 40), ("привет", "мир", 60), ("привет", "мир", 20)])
        let ru = try #require(model.language("ru"))
        #expect(ru.pairLift(previous: fingerprint("привет"), word: fingerprint("мир")) == 60)
    }

    @Test func theOrderOfAddingChangesNoByte() throws {
        let pairs: [(String, String, UInt8)] = [("привет", "мир", 40), ("как", "дела", 255), ("", "привет", 9),
                                                 ("мир", "как", 77), ("дела", "мир", 8)]
        #expect(try model(pairs: pairs).1 == model(pairs: pairs, reversed: true).1)
    }

    @Test func twoKeysOfOneBucketAndOneLowWordAreWrittenInOneOrder() {
        // The same bucket and the same low 32 bits, different keys: a dictionary lists them in the order
        // of its seed, so the writer must not.
        let low: UInt64 = 0x1234_5678
        let one: [UInt64: UInt8] = [low: 5, low | (1 << 40): 9]
        var other: [UInt64: UInt8] = [:]
        for (key, value) in [(low | (1 << 40), UInt8(9)), (low, UInt8(5))] { other[key] = value }
        #expect(LanguageBuilder.fingerprintTable(one, bits: 12) == LanguageBuilder.fingerprintTable(other, bits: 12))
        // The one with the smaller value comes first, whatever the keys.
        let table = LanguageBuilder.fingerprintTable([low | (1 << 40): 3, low: 5], bits: 12)
        #expect(table.suffix(2) == [3, 5])
    }

    @Test func theSectionSizeIsThatOfTheWriterAndNeverFalls() throws {
        var previous = 0
        for count in [1, 2, 100, 3000, 3001, 50_000, 51_000, 400_000, 1_000_000, 1_600_000] {
            let size = ModelBuilder.pairSectionSize(count: count)
            #expect(size >= previous)
            previous = size
        }
        // The same as the bytes of a real section, a few sizes of it.
        for count in [1, 7, 500, 5000] {
            var table: [UInt64: UInt8] = [:]
            for index in 0..<count { table[ModelFormat.pairKey(previous: UInt64(index), word: 7)] = 9 }
            #expect(LanguageBuilder.fingerprintTable(table, bits: ModelBuilder.pairBucketBits(count: count)).count
                == ModelBuilder.pairSectionSize(count: count))
        }
        // 8 MB hold 1.5 million entries and some: the plan's 1.6 million pairs at 5 bytes.
        #expect(ModelBuilder.pairSectionSize(count: 1_500_000) <= ModelFormat.pairBudget)
        #expect(ModelBuilder.pairSectionSize(count: 1_700_000) > ModelFormat.pairBudget)
    }

    // MARK: A damaged section

    /// The model's bytes with the pair section changed by `damage`, and the
    /// checksum made right again: only the section is wrong.
    private func damaged(_ damage: (inout [UInt8], _ section: Range<Int>) -> Void) throws -> [UInt8] {
        var bytes = try model(pairs: [("привет", "мир", 40), ("как", "дела", 255), ("мир", "как", 77)]).1
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) } }
        func u64(_ at: Int) -> Int { (0..<8).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) } }
        var section: Range<Int>?
        for index in 0..<u32(12) {
            let entry = ModelFormat.headerSize + index * ModelFormat.sectionEntrySize
            if UInt32(u32(entry)) == ModelFormat.pairTag { section = u64(entry + 8)..<(u64(entry + 8) + u64(entry + 16)) }
        }
        let range = try #require(section)
        damage(&bytes, range)
        let tableEnd = ModelFormat.headerSize + u32(12) * ModelFormat.sectionEntrySize
        let start = (tableEnd + 7) & ~7
        let checksum = bytes.withUnsafeBytes { ModelFormat.checksum(UnsafeRawBufferPointer(rebasing: $0[start...])) }
        for shift in 0..<8 { bytes[24 + shift] = UInt8((checksum >> UInt64(shift * 8)) & 0xFF) }
        return bytes
    }

    private func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for shift in 0..<4 { bytes[offset + shift] = UInt8((value >> UInt32(shift * 8)) & 0xFF) }
    }

    @Test func theReaderAcceptsTheSectionItWrites() throws {
        let bytes = try damaged { _, _ in }
        #expect(try LanguageModel(bytes: bytes).language("ru")?.hasPairTable == true)
    }

    @Test func theReaderRefusesBucketBitsOutOfRange() throws {
        for bits: UInt32 in [0, 25, 40] {
            let bytes = try damaged { bytes, section in put(bits, into: &bytes, at: section.lowerBound) }
            #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
        }
    }

    @Test func theReaderRefusesACountTheSectionCannotHold() throws {
        let bytes = try damaged { bytes, section in put(1_000_000, into: &bytes, at: section.lowerBound + 4) }
        #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
    }

    @Test func theReaderRefusesBucketsThatDoNotCutTheEntriesInOrder() throws {
        // The first bucket starts after the first entry.
        var bytes = try damaged { bytes, section in put(1, into: &bytes, at: section.lowerBound + 16) }
        #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
        // The last bucket ends before the last entry.
        bytes = try damaged { bytes, section in
            let bits = Int(bytes[section.lowerBound])
            put(2, into: &bytes, at: section.lowerBound + 16 + (1 << bits) * 4)
        }
        #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
        // A bucket that ends where an earlier one ended or sooner.
        bytes = try damaged { bytes, section in
            put(3, into: &bytes, at: section.lowerBound + 16 + 4)
            put(2, into: &bytes, at: section.lowerBound + 16 + 8)
        }
        #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
    }

    @Test func theReaderRefusesASectionShorterThanItsHeader() throws {
        var bytes = try model(pairs: [("привет", "мир", 40)]).1
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << ($1 * 8) } }
        // The table says the pair section is 8 bytes long. The checksum covers the payload only.
        for index in 0..<u32(12) {
            let entry = ModelFormat.headerSize + index * ModelFormat.sectionEntrySize
            if UInt32(u32(entry)) == ModelFormat.pairTag { bytes[entry + 16] = 8; bytes[entry + 17] = 0 }
        }
        #expect(throws: LanguageModel.Error.badSection("pair")) { try LanguageModel(bytes: bytes) }
    }

    @Test func aFileCutShortIsTruncatedBeforeAnySectionIsRead() throws {
        var bytes = try model(pairs: [("привет", "мир", 40)]).1
        bytes.removeLast(16)
        #expect(throws: LanguageModel.Error.truncated) { try LanguageModel(bytes: bytes) }
    }
}
