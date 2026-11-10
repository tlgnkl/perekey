// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyVoice
import PerekeyVoiceCore

/// `dictate-set <id> <speech-dir> [--seconds s] [--runs n] [--instant]`:
/// the app's dictation path (as `dictate`) on the speech set
/// (`scripts/fetch-data.sh speech`), its recordings of a language joined one
/// after another into dictations of up to `s` seconds (60 by default), their
/// references joined the same way. Prints per dictation the time from the
/// stop to the text and the text, then the word and character errors and the
/// stop-to-text times per language. Local only, never in CI; the joined audio
/// stays in memory.
///
/// The audio is fed at its own pace, in blocks of 100 ms against the clock,
/// as a microphone would; `--instant` hands it over at once.
@MainActor
enum DictateSetCommand {
    struct Dictation {
        let language: String
        let files: [String]
        let samples: [Float]
        let reference: String
    }

    struct Row {
        let arm: String
        let run: Int
        let dictation: Dictation
        let stopToText: Double
        let text: String
    }

    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            throw ProbeError.message("dictate-set <id> <speech-dir> [--seconds s] [--runs n] [--instant]")
        }
        let id = arguments[0]
        let folder = URL(filePath: arguments[1], directoryHint: .isDirectory)
        var seconds = 60.0
        var runs = 1
        var instant = false
        var rest = arguments.dropFirst(2)[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--seconds": seconds = Double(rest.popFirst() ?? "") ?? seconds
            case "--runs": runs = Int(rest.popFirst() ?? "") ?? 1
            case "--instant": instant = true
            default: throw ProbeError.message("unknown option \(argument)")
            }
        }
        let dictations = try joined(folder, seconds: seconds)
        guard let first = dictations.first else { throw ProbeError.message("no recordings in \(folder.path)") }

        guard let root = ProcessInfo.processInfo.environment["PEREKEY_VOICE_MODELS"] else {
            throw ProbeError.message("set PEREKEY_VOICE_MODELS to the models folder")
        }
        let models = URL(filePath: root, directoryHint: .isDirectory)
        let store = VoiceModelStore(
            locations: VoiceModelLocations(models: models, managed: models.appending(path: "../managed").standardized,
                                           coreMLCache: models.appending(path: "../coreml-cache").standardized),
            managed: ManagedSettings())
        guard await store.status(of: id)?.state == .ready else { throw ProbeError.message("\(id) is not ready") }

        let microphone = FileMicrophone()
        let paster = PrintPaster()
        let preferences = DictationPreferences(modelID: id, switchesLayout: false, playsSounds: false,
                                               silenceStop: nil, unloadAfter: nil)
        let controller = VoiceController(
            preferences: preferences, microphone: microphone, paster: paster, secureInput: nil,
            detector: SileroVAD(store: store), makeEngine: { VoiceEngines.make(model: $0, store: store) },
            hooks: VoiceController.Hooks(play: { _ in }))

        // Warm-up: the model loads and CoreML compiles; its time is not the model's.
        _ = try await dictate(first.samples, controller: controller, microphone: microphone, paster: paster,
                              instant: true)
        var rows: [Row] = []
        print("row\tarm\trun\tlanguage\tspeech_s\tstop_to_text_s\tfiles\treference\ttext")
        for run in 0..<runs {
            for dictation in dictations {
                let (stopToText, text) = try await dictate(dictation.samples, controller: controller,
                                                           microphone: microphone, paster: paster, instant: instant)
                let row = Row(arm: "whole", run: run, dictation: dictation, stopToText: stopToText, text: text)
                rows.append(row)
                print("row\t\(row.arm)\t\(run)\t\(dictation.language)\t"
                    + String(format: "%.1f\t%.3f", Double(dictation.samples.count) / VoiceCore.sampleRate, stopToText)
                    + "\t\(dictation.files.joined(separator: ","))\t\(dictation.reference)\t\(text)")
            }
        }
        await controller.unloadModels()
        summary(id: id, seconds: seconds, instant: instant, rows: rows)
    }

    /// The recordings of each language, in the order of `refs.tsv`, joined
    /// while the dictation stays within `seconds`. A recording longer than
    /// that is a dictation of its own.
    static func joined(_ folder: URL, seconds: Double) throws -> [Dictation] {
        let limit = Int(seconds * VoiceCore.sampleRate)
        var dictations: [Dictation] = []
        for language in ["ru", "en"] {
            let directory = folder.appending(path: language, directoryHint: .isDirectory)
            guard let table = try? String(contentsOf: directory.appending(path: "refs.tsv"), encoding: .utf8) else { continue }
            var files: [String] = []
            var samples: [Float] = []
            var references: [String] = []
            func close() {
                guard !files.isEmpty else { return }
                dictations.append(Dictation(language: language, files: files, samples: samples,
                                            reference: references.joined(separator: " ")))
                files = []
                samples = []
                references = []
            }
            for line in table.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let audio = try Engines.samples(directory.appending(path: String(parts[0])).path)
                if !samples.isEmpty, samples.count + audio.count > limit { close() }
                files.append(String(parts[0]))
                samples += audio
                references.append(String(parts[1]))
            }
            close()
        }
        return dictations
    }

    /// One dictation through the controller: the seconds from the stop to
    /// the text, and the text (or the HUD state when nothing was pasted).
    static func dictate(_ samples: [Float], controller: VoiceController, microphone: FileMicrophone,
                        paster: PrintPaster, instant: Bool) async throws -> (Double, String)
    {
        controller.voice(.toggle)
        try await until { if case .recording = controller.state { true } else { false } }
        if instant {
            microphone.push(samples)
        } else {
            let block = Int(VoiceCore.sampleRate) / 10
            let start = ContinuousClock.now
            for (index, offset) in stride(from: 0, to: samples.count, by: block).enumerated() {
                microphone.push(Array(samples[offset..<min(samples.count, offset + block)]))
                try await Task.sleep(until: start + .milliseconds(100 * (index + 1)), clock: .continuous)
            }
        }
        let stop = ContinuousClock.now
        controller.voice(.toggle)
        try await until { controller.state == .idle }
        let elapsed = ContinuousClock.now - stop
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let text: String = switch controller.hud {
        case .pasted: paster.last ?? ""
        case let other: "<\(other)>"
        }
        return (seconds, text)
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(900)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeError.message("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Per arm and language: the errors over all runs, and the stop-to-text
    /// time of a dictation as the median of its runs.
    static func summary(id: String, seconds: Double, instant: Bool, rows: [Row]) {
        for arm in Set(rows.map(\.arm)).sorted() {
            let mine = rows.filter { $0.arm == arm }
            var result: [String: Any] = ["model": id, "arm": arm, "seconds": seconds, "instant": instant]
            var all = SpeechScore.Tally()
            var allTimes: [Double] = []
            for language in ["ru", "en"] {
                let these = mine.filter { $0.dictation.language == language }
                guard !these.isEmpty else { continue }
                var tally = SpeechScore.Tally()
                for row in these {
                    tally.add(reference: row.dictation.reference, hypothesis: row.text)
                    all.add(reference: row.dictation.reference, hypothesis: row.text)
                }
                let times = Dictionary(grouping: these, by: { $0.dictation.files }).values
                    .map { ScoreCommand.median($0.map(\.stopToText)) }
                allTimes += times
                result[language] = stats(tally, times)
            }
            result["all"] = stats(all, allTimes)
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("summary\t" + String(decoding: data ?? Data(), as: UTF8.self))
        }
    }

    private static func stats(_ tally: SpeechScore.Tally, _ times: [Double]) -> [String: Any] {
        let sorted = times.sorted()
        return [
            "dictations": times.count, "wer": tally.wordErrorRate, "cer": tally.characterErrorRate,
            "word_errors": tally.wordErrors, "reference_words": tally.referenceWords,
            "median_stop_to_text": ScoreCommand.median(sorted),
            "p90_stop_to_text": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))],
            "max_stop_to_text": sorted.last ?? 0,
        ]
    }
}
