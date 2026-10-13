// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import WhisperKit

/// WhisperKit whose tokenizer comes from the model's folder and nowhere
/// else. WhisperKit's own load falls back to the Hugging Face Hub on any
/// local error, without a word: past the store, its checksums and the
/// profile. Here a tokenizer that does not load is a broken model.
final class StoreWhisperKit: WhisperKit {
    private let localTokenizer: LocalWhisperTokenizer

    /// `config` must not load: the tokenizer is set before the models are.
    init(_ config: WhisperKitConfig, tokenizer: LocalWhisperTokenizer) async throws {
        localTokenizer = tokenizer
        try await super.init(config)
    }

    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer == nil else { return }
        guard let logits = textDecoder.logitsSize else {
            throw WhisperError.tokenizerUnavailable()
        }
        // As WhisperKit does: 51864 logits is an English-only model. Without
        // it, language detection and every language but English break.
        textDecoder.isModelMultilingual = logits != 51864
        tokenizer = localTokenizer
    }
}

public enum WhisperTokenizerError: Error, Equatable {
    case unreadable(String)
}

/// Whisper's tokenizer from a folder of `tokenizer.json` and its configs,
/// as `WhisperTokenizerWrapper` builds it (its initializer is internal).
/// Special tokens missing from the vocabulary fall back to Whisper's base
/// ids, as there.
struct LocalWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(folder: URL) async throws {
        do {
            tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder)
        } catch {
            throw WhisperTokenizerError.unreadable(String(describing: error))
        }
        let tokenizer = self.tokenizer
        func id(_ token: String, _ base: Int) -> Int { tokenizer.convertTokenToId(token) ?? base }
        let specialTokens = SpecialTokens(
            endToken: id("<|endoftext|>", 50257),
            englishToken: id("<|en|>", 50259),
            noSpeechToken: id("<|nospeech|>", 50362),
            noTimestampsToken: id("<|notimestamps|>", 50363),
            specialTokenBegin: id("<|endoftext|>", 50257),
            startOfPreviousToken: id("<|startofprev|>", 50361),
            startOfTranscriptToken: id("<|startoftranscript|>", 50258),
            timeTokenBegin: id("<|0.00|>", 50364),
            transcribeToken: id("<|transcribe|>", 50359),
            translateToken: id("<|translate|>", 50358),
            whitespaceToken: id(" ", 220))
        self.specialTokens = specialTokens
        allLanguageTokens = Set(
            Constants.languages.values
                .compactMap { tokenizer.convertTokenToId("<|\($0)|>") }
                .filter { $0 > specialTokens.specialTokenBegin })
        // A vocabulary without Whisper's tokens is not Whisper's tokenizer.
        guard tokenizer.convertTokenToId("<|startoftranscript|>") != nil, !allLanguageTokens.isEmpty else {
            throw WhisperTokenizerError.unreadable("no Whisper special tokens in \(folder.lastPathComponent)")
        }
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    /// Words by spaces and punctuation, for word timings, which dictation
    /// does not ask for. WhisperKit's splits Chinese, Japanese and Thai by
    /// characters as well; this one does not.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let piece = tokenizer.decode(tokens: pending)
            // Part of a character split over tokens: wait for the rest.
            if piece.contains("\u{fffd}") { continue }
            let special = pending.first! >= specialTokens.specialTokenBegin
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let punctuation = !trimmed.isEmpty
                && trimmed.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
            if special || piece.hasPrefix(" ") || punctuation || words.isEmpty {
                words.append(piece)
                wordTokens.append(pending)
            } else {
                words[words.count - 1] += piece
                wordTokens[wordTokens.count - 1] += pending
            }
            pending = []
        }
        return (words, wordTokens)
    }
}
