// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

/// The keyed fingerprint of the personal lexicon (docs/classifier.md,
/// «Личный словарь»).
@Suite struct SipHashTests {
    /// `vectors_sip64` of the reference implementation (github.com/veorq/SipHash,
    /// `vectors.h`): SipHash-2-4, 64-bit result, key `00 01 … 0f`, input
    /// `00 01 …` of length 0 to 63, each value read little-endian.
    static let vectors: [UInt64] = [
        0x726f_db47_dd0e_0e31, 0x74f8_39c5_93dc_67fd, 0x0d6c_8009_d9a9_4f5a, 0x8567_6696_d7fb_7e2d,
        0xcf27_94e0_2771_87b7, 0x1876_5564_cd99_a68d, 0xcbc9_466e_58fe_e3ce, 0xab02_00f5_8b01_d137,
        0x93f5_f579_9a93_2462, 0x9e00_82df_0ba9_e4b0, 0x7a5d_bbc5_94dd_b9f3, 0xf4b3_2f46_226b_ada7,
        0x751e_8fbc_860e_e5fb, 0x14ea_5627_c084_3d90, 0xf723_ca90_8e7a_f2ee, 0xa129_ca61_49be_45e5,
        0x3f2a_cc7f_57c2_9bdb, 0x699a_e9f5_2cbe_4794, 0x4bc1_b3f0_968d_d39c, 0xbb6d_c91d_a779_61bd,
        0xbed6_5cf2_1aa2_ee98, 0xd0f2_cbb0_2e3b_67c7, 0x9353_6795_e3a3_3e88, 0xa80c_038c_cd5c_cec8,
        0xb8ad_50c6_f649_af94, 0xbce1_92de_8a85_b8ea, 0x17d8_35b8_5bbb_15f3, 0x2f2e_6163_076b_cfad,
        0xde4d_aaac_a71d_c9a5, 0xa6a2_5066_8795_6571, 0xad87_a353_5c49_ef28, 0x32d8_92fa_d841_c342,
        0x7127_512f_72f2_7cce, 0xa7f3_2346_f959_78e3, 0x12e0_b01a_bb05_1238, 0x15e0_34d4_0fa1_97ae,
        0x314d_ffbe_0815_a3b4, 0x0279_90f0_2962_3981, 0xcadc_d4e5_9ef4_0c4d, 0x9abf_d876_6a33_735c,
        0x0e3e_a96b_5304_a7d0, 0xad0c_42d6_fc58_5992, 0x1873_06c8_9bc2_15a9, 0xd4a6_0abc_f379_2b95,
        0xf935_451d_e4f2_1df2, 0xa953_8f04_1975_5787, 0xdb9a_cddf_f56c_a510, 0xd06c_98cd_5c09_75eb,
        0xe612_a3cb_9ecb_a951, 0xc766_e62c_fcad_af96, 0xee64_435a_9752_fe72, 0xa192_d576_b245_165a,
        0x0a87_87bf_8ecb_74b2, 0x81b3_e73d_20b4_9b6f, 0x7fa8_220b_a3b2_ecea, 0x2457_31c1_3ca4_2499,
        0xb78d_bfaf_3a8d_83bd, 0xea1a_d565_322a_1a0b, 0x60e6_1c23_a379_5013, 0x6606_d7e4_4628_2b93,
        0x6ca4_ecb1_5c5f_91e1, 0x9f62_6da1_5c96_25f3, 0xe51b_3860_8ef2_5f57, 0x958a_324c_eb06_4572,
    ]

    static let k0: UInt64 = 0x0706_0504_0302_0100
    static let k1: UInt64 = 0x0F0E_0D0C_0B0A_0908

    @Test func matchesTheReferenceVectors() {
        #expect(Self.vectors.count == 64)
        for length in 0..<64 {
            let input = (0..<length).map { UInt8($0) }
            #expect(SipHash24.hash(k0: Self.k0, k1: Self.k1, input) == Self.vectors[length], "length \(length)")
        }
    }

    @Test func twoValuesCheckedAgainstThePaper() {
        // Recomputed apart from the table (plan 15): the empty input and 15 bytes.
        #expect(SipHash24.hash(k0: Self.k0, k1: Self.k1, []) == 0x726F_DB47_DD0E_0E31)
        #expect(SipHash24.hash(k0: Self.k0, k1: Self.k1, (0..<15).map { UInt8($0) }) == 0xA129_CA61_49BE_45E5)
    }

    @Test func aKeyOfSixteenBytesIsTheReferenceKey() throws {
        let key = try #require(PersonalKey(bytes: (0..<16).map { UInt8($0) }))
        #expect(key == PersonalKey(k0: Self.k0, k1: Self.k1))
        #expect(PersonalKey(bytes: [UInt8](repeating: 1, count: 15)) == nil)
    }

    @Test func fourBytesLittleEndianAreFourBytes() {
        var bytes = SipHash24(k0: Self.k0, k1: Self.k1)
        for byte: UInt8 in [0x04, 0x03, 0x02, 0x01] { bytes.append(byte) }
        var word = SipHash24(k0: Self.k0, k1: Self.k1)
        word.append(littleEndian: 0x0102_0304)
        #expect(bytes.finalize() == word.finalize())
    }
}

/// A test key: the reference one.
let personalKey = PersonalKey(k0: SipHashTests.k0, k1: SipHashTests.k1)

/// The observation of a word, as the machine makes it.
func personalObservation(_ word: String, _ language: String, key: PersonalKey = personalKey) -> PersonalObservation {
    let scalars = word.unicodeScalars.map(\.value)
    return PersonalObservation(word: key.fingerprint(.word, language: language, scalars),
                               start3: key.fingerprint(.start3, language: language, scalars.prefix(3)),
                               start4: scalars.count >= 4 ? key.fingerprint(.start4, language: language, scalars.prefix(4)) : nil,
                               language: language)
}

/// A lexicon that has these words, each in its language.
func personalLexicon(_ words: [(String, String)], generation: UInt32 = 0) -> PersonalLexicon {
    let observations = words.map { personalObservation($0.0, $0.1) }
    return PersonalLexicon(key: personalKey, words: observations.map(\.word),
                           starts: observations.flatMap { [$0.start3] + ($0.start4.map { [$0] } ?? []) },
                           generation: generation)
}

@Suite struct PersonalFingerprintTests {
    @Test func domainLanguageAndScalarsMakeTheInput() {
        // Domain 1, "ru", 0, then "да" as two scalars of four bytes each.
        var hasher = SipHash24(key: personalKey)
        for byte: UInt8 in [1, 0x72, 0x75, 0] { hasher.append(byte) }
        for scalar: UInt32 in [0x434, 0x430] { hasher.append(littleEndian: scalar) }
        #expect(personalKey.fingerprint(ofWord: "да", language: "ru") == hasher.finalize())
    }

    @Test func yoIsYeAndCaseIsFolded() {
        let artem = personalKey.fingerprint(ofWord: "артем", language: "ru")
        #expect(personalKey.fingerprint(ofWord: "артём", language: "ru") == artem)
        #expect(personalKey.fingerprint(ofWord: "Артём", language: "ru") == artem)
        #expect(personalKey.fingerprint(ofWord: "АРТЁМ", language: "ru") == artem)
    }

    @Test func domainsLanguagesAndKeysDiffer() {
        let scalars = "дашка".unicodeScalars.map(\.value)
        let word = personalKey.fingerprint(.word, language: "ru", scalars.prefix(3))
        #expect(personalKey.fingerprint(.start3, language: "ru", scalars.prefix(3)) != word)
        #expect(personalKey.fingerprint(.word, language: "uk", scalars.prefix(3)) != word)
        #expect(PersonalKey(k0: 1, k1: 2).fingerprint(.word, language: "ru", scalars.prefix(3)) != word)
        // The model's own, unkeyed fingerprint is another number.
        #expect(ModelFormat.Fingerprint.of("даш".unicodeScalars, folded: true) != word)
    }
}

@Suite struct PersonalLexiconSnapshotTests {
    @Test func findsWhatItHoldsAndNothingElse() {
        let lexicon = PersonalLexicon(key: personalKey, words: [9, 3, 7, 3, 1], starts: [5])
        #expect(lexicon.words == [1, 3, 7, 9])
        #expect(lexicon.wordCount == 4)
        for word: UInt64 in [1, 3, 7, 9] { #expect(lexicon.containsWord(word)) }
        for word: UInt64 in [0, 2, 5, 8, 10, .max] { #expect(!lexicon.containsWord(word)) }
        #expect(lexicon.containsStart(5) && !lexicon.containsStart(9))
        #expect(lexicon.isOn && lexicon.hasWords)
    }

    @Test func offAndEmptyLookNothingUp() throws {
        #expect(!PersonalLexicon.off.isOn && !PersonalLexicon.off.hasWords && PersonalLexicon.off.key == nil)
        let empty = PersonalLexicon(key: personalKey, words: [], starts: [])
        #expect(empty.isOn && !empty.hasWords)
        let classifier = Classifier(model: ModelFixture.model)
        let strokes = Fixture.russian.strokes("дашка")
        #expect(!classifier.isPersonal(strokes, in: Fixture.russian, personal: empty))
        #expect(!classifier.isPersonal(strokes, in: Fixture.russian, personal: .off))
        #expect(classifier.isPersonal(strokes, in: Fixture.russian, personal: personalLexicon([("дашка", "ru")])))
    }

    @Test func aCopyIsTheSameStorage() {
        let lexicon = personalLexicon([("дашка", "ru")])
        let copy = lexicon
        #expect(copy == lexicon)
        #expect(personalLexicon([("дашка", "ru")]) == lexicon)
        #expect(personalLexicon([("дашка", "ru")], generation: 1) != lexicon)
        #expect(lexicon != .off)
    }

    @Test func theSessionFormatKeepsItAsHex() throws {
        let lexicon = PersonalLexicon(key: personalKey, words: [1, .max], starts: [2], generation: 3)
        let json = try #require(String(data: JSONEncoder().encode(lexicon), encoding: .utf8))
        #expect(json.contains("\"07060504030201000f0e0d0c0b0a0908\""))
        #expect(json.contains("\"ffffffffffffffff\""))
        let read = try JSONDecoder().decode(PersonalLexicon.self, from: Data(json.utf8))
        #expect(read == lexicon)
        let off = try JSONDecoder().decode(PersonalLexicon.self, from: JSONEncoder().encode(PersonalLexicon.off))
        #expect(off == .off)
    }
}

@Suite struct PersonalLexiconModelTests {
    let word = personalObservation("дашка", "ru")

    func batch(_ observations: [PersonalObservation], generation: UInt32 = 0) -> PersonalTally {
        PersonalTally(observations: observations, generation: generation)
    }

    @Test func fiveObservationsOnThreeDaysAcceptAWord() {
        var model = PersonalLexiconModel()
        do { let changed = model.record(batch([word, word]), day: 10); #expect(!changed) }
        do { let changed = model.record(batch([word]), day: 11); #expect(!changed) }
        do { let changed = model.record(batch([word]), day: 11); #expect(!changed) }
        do { let changed = model.record(batch([word]), day: 12); #expect(changed) }
        #expect(model.acceptedCount == 1 && model.candidateCount == 0)
        let snapshot = model.snapshot(key: personalKey)
        #expect(snapshot.words == [word.word])
        #expect(Set(snapshot.starts) == [word.start3, word.start4!])
        // Seen again: still one word, nothing changed for the tap.
        do { let changed = model.record(batch([word]), day: 13); #expect(!changed) }
    }

    @Test func manyObservationsOnTwoDaysAreNotEnough() {
        var model = PersonalLexiconModel()
        model.record(batch(Array(repeating: word, count: 20)), day: 1)
        model.record(batch(Array(repeating: word, count: 20)), day: 2)
        #expect(model.acceptedCount == 0)
        #expect(model.entries[word.word]?.count == 40 && model.entries[word.word]?.days == 2)
    }

    @Test func aBatchOfAnOldGenerationIsDropped() {
        var model = PersonalLexiconModel()
        model.record(batch([word]), day: 1)
        model.erase()
        #expect(model.entries.isEmpty && model.generation == 1)
        do { let changed = model.record(batch([word], generation: 0), day: 2); #expect(!changed) }
        #expect(model.entries.isEmpty)
        model.record(batch([word], generation: 1), day: 2)
        #expect(model.entries.count == 1)
    }

    @Test func forgetDropsAWordAtOnce() {
        var model = PersonalLexiconModel()
        for day in 1...5 { model.record(batch([word]), day: day) }
        #expect(model.acceptedCount == 1)
        do { let changed = model.forget(personalKey.fingerprint(ofWord: "Дашка", language: "ru")); #expect(changed) }
        #expect(model.entries.isEmpty && model.acceptedCount == 0)
        do { let changed = model.forget(word.word); #expect(!changed) }
    }

    @Test func wordsAndCandidatesExpire() {
        var model = PersonalLexiconModel()
        let other = personalObservation("колян", "ru")
        for day in 1...5 { model.record(batch([word]), day: day) }
        model.record(batch([other]), day: 5)
        let options = PersonalOptions()
        do { let changed = model.expire(today: 5 + options.candidateLifetime); #expect(!changed) }
        #expect(model.entries.count == 2)
        do { let changed = model.expire(today: 5 + options.candidateLifetime + 1); #expect(!changed) }
        #expect(model.entries.keys.sorted() == [word.word])
        do { let changed = model.expire(today: 5 + options.wordLifetime); #expect(!changed) }
        do { let changed = model.expire(today: 5 + options.wordLifetime + 1); #expect(changed) }
        #expect(model.entries.isEmpty && model.acceptedCount == 0)
    }

    @Test func theOldestGoFirstWhenFull() {
        var options = PersonalOptions()
        options.maxCandidates = 2
        options.maxWords = 1
        options.promoteCount = 2
        options.promoteDays = 1
        var model = PersonalLexiconModel(options: options)
        let a = personalObservation("аааа", "ru")
        let b = personalObservation("бббб", "ru")
        let c = personalObservation("вввв", "ru")
        model.record(batch([a]), day: 1)
        model.record(batch([b]), day: 2)
        model.record(batch([c]), day: 3)
        #expect(Set(model.entries.keys) == [b.word, c.word])
        model.record(batch([b]), day: 4)
        #expect(model.acceptedCount == 1)
        model.record(batch([c]), day: 5)
        // c is accepted, b was seen longer ago and goes.
        #expect(model.acceptedCount == 1 && model.entries[c.word]?.accepted == true && model.entries[b.word] == nil)
    }
}
