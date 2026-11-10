// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore

/// `score <id> <speech-dir> [--hint | --both] [--head s] [--runs n]`: the
/// speech set (`scripts/fetch-data.sh speech`, a folder per language with
/// `refs.tsv` and the recordings) through one model. Prints the word and
/// character error rates against the reference, case and punctuation aside,
/// and the time the model takes. Local only, never in CI.
///
/// - `--hint`: the language of the folder goes to the model as the hint of
///   `DictationLanguageHint`; without it the model finds the language itself.
/// - `--both`: each recording with and without the hint, back to back and in
///   alternating order, so a busy machine and a warm model touch both arms
///   alike. Prints a summary per arm.
/// - `--head s`: only the first `s` seconds of each recording. The set has
///   no phrases of one to three words; this stands in for them. The
///   reference is cut by the share of the words (`SpeechScore.leadingWords`).
/// - `--runs n`: the set `n` times. Errors are counted over all the runs
///   (Whisper may decode a hard recording differently each time); the time
///   of a recording is the median of its runs.
enum ScoreCommand {
    struct Row {
        let hint: Bool
        let run: Int
        let language: String
        let file: String
        let seconds: Double
        let text: String
        let reference: String
        let wrongScript: Bool
    }

    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            throw ProbeError.message("score <id> <speech-dir> [--hint | --both] [--head s] [--runs n]")
        }
        let id = arguments[0]
        let folder = URL(filePath: arguments[1], directoryHint: .isDirectory)
        var arms = [false]
        var head: Double?
        var runs = 1
        var rest = arguments.dropFirst(2)[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--hint": arms = [true]
            case "--both": arms = [false, true]
            case "--head": head = Double(rest.popFirst() ?? "")
            case "--runs": runs = Int(rest.popFirst() ?? "") ?? 1
            default: throw ProbeError.message("unknown option \(argument)")
            }
        }
        let engine = try Engines.make(id)
        try await engine.load()
        var rows: [Row] = []
        for language in ["ru", "en"] {
            let directory = folder.appending(path: language, directoryHint: .isDirectory)
            guard let table = try? String(contentsOf: directory.appending(path: "refs.tsv"), encoding: .utf8) else { continue }
            let entries = table.split(separator: "\n").compactMap { line -> (file: String, reference: String)? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
            guard let first = entries.first else { continue }
            // Warm-up: the first call compiles and caches; its time is not the model's.
            for arm in arms {
                _ = try await engine.transcribe(try Engines.samples(directory.appending(path: first.file).path),
                                                language: arm ? language : nil)
            }
            for run in 0..<runs {
                for (index, entry) in entries.enumerated() {
                    var samples = try Engines.samples(directory.appending(path: entry.file).path)
                    var reference = entry.reference
                    if let head {
                        let keep = min(samples.count, Int(head * VoiceCore.sampleRate))
                        reference = SpeechScore.leadingWords(
                            of: entry.reference, share: Double(keep) / Double(max(1, samples.count)))
                        samples = Array(samples.prefix(keep))
                    }
                    for arm in (index + run) % 2 == 0 ? arms : arms.reversed() {
                        let start = ContinuousClock.now
                        let text = try await engine.transcribe(samples, language: arm ? language : nil)
                        let elapsed = ContinuousClock.now - start
                        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                        rows.append(Row(hint: arm, run: run, language: language, file: entry.file, seconds: seconds,
                                        text: text, reference: reference, wrongScript: !hasScript(of: language, text)))
                    }
                }
            }
        }
        await engine.unload()
        for arm in arms { report(id: id, hint: arm, head: head, rows: rows.filter { $0.hint == arm }) }
    }

    /// Whether most letters of `text` are in the script of `language`; text
    /// with no letter at all has the wrong one.
    static func hasScript(of language: String, _ text: String) -> Bool {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 } else if scalar.value < 0x0250 { latin += 1 }
        }
        return language == "ru" ? cyrillic > latin : latin > cyrillic
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// The rows of one arm: the texts of the first run, then the summary.
    static func report(id: String, hint: Bool, head: Double?, rows: [Row]) {
        print("row\thint\tlanguage\tfile\tseconds\treference\ttext")
        for row in rows where row.run == 0 {
            print("row\t\(hint)\t\(row.language)\t\(row.file)\t\(String(format: "%.3f", row.seconds))\t\(row.reference)\t\(row.text)")
        }
        var summary: [String: Any] = ["model": id, "hint": hint, "head_seconds": head.map { $0 as Any } ?? NSNull()]
        var all = SpeechScore.Tally()
        var allTimes: [Double] = []
        var allWrong = 0
        var allHeard = 0
        for language in ["ru", "en"] {
            let mine = rows.filter { $0.language == language }
            guard !mine.isEmpty else { continue }
            var tally = SpeechScore.Tally()
            for row in mine {
                tally.add(reference: row.reference, hypothesis: row.text)
                all.add(reference: row.reference, hypothesis: row.text)
            }
            // The time of a recording is the median of its runs.
            let perRecording = Dictionary(grouping: mine, by: \.file).values.map { median($0.map(\.seconds)) }
            allTimes += perRecording
            let wrong = mine.filter(\.wrongScript).count
            allWrong += wrong
            allHeard += mine.count
            summary[language] = [
                "heard": mine.count, "recordings": perRecording.count, "wer": tally.wordErrorRate,
                "cer": tally.characterErrorRate, "word_errors": tally.wordErrors, "reference_words": tally.referenceWords,
                "median_seconds": median(perRecording), "mean_seconds": perRecording.reduce(0, +) / Double(perRecording.count),
                "wrong_script": wrong,
            ]
        }
        summary["all"] = [
            "heard": allHeard, "recordings": allTimes.count, "wer": all.wordErrorRate, "cer": all.characterErrorRate,
            "word_errors": all.wordErrors, "reference_words": all.referenceWords,
            "median_seconds": median(allTimes), "mean_seconds": allTimes.isEmpty ? 0 : allTimes.reduce(0, +) / Double(allTimes.count),
            "wrong_script": allWrong,
        ]
        let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("summary\t" + String(decoding: data ?? Data(), as: UTF8.self))
    }
}
