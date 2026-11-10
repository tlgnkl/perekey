// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoiceCore

/// `score <id> <speech-dir> [--hint] [--head s] [--runs n]`: the speech set
/// (`scripts/fetch-data.sh speech`, a folder per language with `refs.tsv`
/// and the recordings) through one model. Prints the word and character
/// error rates against the reference, case and punctuation aside, and the
/// time the model takes. Local only, never in CI.
///
/// - `--hint`: the language of the folder goes to the model as the hint of
///   `DictationLanguageHint`; without it the model finds the language.
/// - `--head s`: only the first `s` seconds of each recording. The set has
///   no phrases of one to three words; this stands in for them. The
///   reference is cut by the share of the words (`SpeechScore.leadingWords`).
/// - `--runs n`: the set `n` times; the first run's text is scored, the time
///   is the median of the runs.
enum ScoreCommand {
    struct Row {
        let language: String
        let file: String
        let seconds: Double
        let text: String
        let reference: String
        let wrongScript: Bool
    }

    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw ProbeError.message("score <id> <speech-dir> [--hint] [--head s] [--runs n]") }
        let id = arguments[0]
        let folder = URL(filePath: arguments[1], directoryHint: .isDirectory)
        var hint = false
        var head: Double?
        var runs = 1
        var rest = arguments.dropFirst(2)[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--hint": hint = true
            case "--head": head = Double(rest.popFirst() ?? "")
            case "--runs": runs = Int(rest.popFirst() ?? "") ?? 1
            default: throw ProbeError.message("unknown option \(argument)")
            }
        }
        let engine = try Engines.make(id)
        try await engine.load()
        var rows: [Row] = []
        var times: [String: [[Double]]] = [:]
        for language in ["ru", "en"] {
            let directory = folder.appending(path: language, directoryHint: .isDirectory)
            guard let table = try? String(contentsOf: directory.appending(path: "refs.tsv"), encoding: .utf8) else { continue }
            let entries = table.split(separator: "\n").compactMap { line -> (file: String, reference: String)? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
            guard let first = entries.first else { continue }
            // Warm-up: the first call compiles and caches; its time is not the model's.
            _ = try await engine.transcribe(try Engines.samples(directory.appending(path: first.file).path),
                                            language: hint ? language : nil)
            for run in 0..<runs {
                var runTimes: [Double] = []
                for entry in entries {
                    var samples = try Engines.samples(directory.appending(path: entry.file).path)
                    var reference = entry.reference
                    if let head {
                        let keep = min(samples.count, Int(head * VoiceCore.sampleRate))
                        reference = SpeechScore.leadingWords(
                            of: entry.reference, share: Double(keep) / Double(max(1, samples.count)))
                        samples = Array(samples.prefix(keep))
                    }
                    let start = ContinuousClock.now
                    let text = try await engine.transcribe(samples, language: hint ? language : nil)
                    let elapsed = ContinuousClock.now - start
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    runTimes.append(seconds)
                    if run == 0 {
                        rows.append(Row(language: language, file: entry.file, seconds: seconds, text: text,
                                        reference: reference, wrongScript: !hasScript(of: language, text)))
                    }
                }
                times[language, default: []].append(runTimes)
            }
        }
        await engine.unload()
        report(id: id, hint: hint, head: head, rows: rows, times: times)
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

    static func report(id: String, hint: Bool, head: Double?, rows: [Row], times: [String: [[Double]]]) {
        print("row\tlanguage\tfile\tseconds\treference\ttext")
        for row in rows {
            print("row\t\(row.language)\t\(row.file)\t\(String(format: "%.3f", row.seconds))\t\(row.reference)\t\(row.text)")
        }
        var summary: [String: Any] = ["model": id, "hint": hint, "head_seconds": head.map { $0 as Any } ?? NSNull()]
        var all = SpeechScore.Tally()
        var allTimes: [Double] = []
        var allWrong = 0
        for language in ["ru", "en"] {
            let mine = rows.filter { $0.language == language }
            guard !mine.isEmpty else { continue }
            var tally = SpeechScore.Tally()
            for row in mine {
                tally.add(reference: row.reference, hypothesis: row.text)
                all.add(reference: row.reference, hypothesis: row.text)
            }
            // Per recording, the median over the runs; then the median and the mean over recordings.
            let runs = times[language] ?? []
            let perRecording = mine.indices.map { index in median(runs.map { $0[index] }) }
            allTimes += perRecording
            let wrong = mine.filter(\.wrongScript).count
            allWrong += wrong
            summary[language] = [
                "recordings": tally.recordings, "wer": tally.wordErrorRate, "cer": tally.characterErrorRate,
                "word_errors": tally.wordErrors, "reference_words": tally.referenceWords,
                "median_seconds": median(perRecording), "mean_seconds": perRecording.reduce(0, +) / Double(perRecording.count),
                "wrong_script": wrong,
            ]
        }
        summary["all"] = [
            "recordings": all.recordings, "wer": all.wordErrorRate, "cer": all.characterErrorRate,
            "word_errors": all.wordErrors, "reference_words": all.referenceWords,
            "median_seconds": median(allTimes), "mean_seconds": allTimes.isEmpty ? 0 : allTimes.reduce(0, +) / Double(allTimes.count),
            "wrong_script": allWrong,
        ]
        let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("summary\t" + String(decoding: data ?? Data(), as: UTF8.self))
    }
}
