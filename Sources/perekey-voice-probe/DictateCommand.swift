// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// `dictate <id> <audio>... [--realtime] [--runs n]`: the app's dictation
/// path, VoiceController with the store's engine and Silero VAD, fed from
/// files instead of the microphone. Prints, per file, the time from the end
/// of speech (the stop) to the text, and the text. `--realtime` feeds the
/// audio at its own pace, so the model loads while it is "spoken", as in
/// the app; otherwise it all arrives at once.
@MainActor
enum DictateCommand {
    static func run(_ arguments: [String]) async throws {
        guard let id = arguments.first else { throw ProbeError.message("dictate <id> <audio>... [--realtime] [--runs n]") }
        var files: [String] = []
        var realtime = false
        var runs = 1
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--realtime": realtime = true
            case "--runs": runs = Int(rest.popFirst() ?? "") ?? 1
            default: files.append(argument)
            }
        }
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
        let before = MemorySnapshot.now()
        print("model\tfile\tspeech_s\tstop_to_text_s\tfirst\ttext")
        var first = true
        for _ in 0..<runs {
            for file in files {
                let samples = try Engines.samples(file)
                controller.voice(.toggle)
                try await until { if case .recording = controller.state { true } else { false } }
                if realtime {
                    let block = Int(VoiceCore.sampleRate) / 10
                    for start in stride(from: 0, to: samples.count, by: block) {
                        microphone.push(Array(samples[start..<min(samples.count, start + block)]))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } else {
                    microphone.push(samples)
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
                let name = URL(fileURLWithPath: file).lastPathComponent
                print(String(format: "%@\t%@\t%.1f\t%.2f\t%@\t%@", id, name, Double(samples.count) / VoiceCore.sampleRate,
                             seconds, first ? "yes" : "no", text))
                first = false
            }
        }
        let loaded = MemorySnapshot.now()
        await controller.unloadModels()
        let unloaded = MemorySnapshot.now()
        print(String(format: "memory MB (rss/footprint): before %.0f/%.0f, loaded %.0f/%.0f, unloaded %.0f/%.0f",
                     before.rssMB, before.footprintMB, loaded.rssMB, loaded.footprintMB, unloaded.rssMB,
                     unloaded.footprintMB))
        print("requests: \(VoiceHTTP.shared.requests.count)")
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(900)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeError.message("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The microphone, from a file: the command pushes the samples.
private final class FileMicrophone: DictationMicrophone, @unchecked Sendable {
    private let lock = NSLock()
    private var audio: DictationAudio?

    func begin(_ audio: DictationAudio) async throws -> AudioSubscription {
        lock.withLock { self.audio = audio }
        return AudioSubscription(id: 1)
    }

    func end(_: AudioSubscription) async {
        lock.withLock { audio = nil }
    }

    func push(_ samples: [Float]) {
        let audio = lock.withLock { self.audio }
        samples.withUnsafeBufferPointer { audio?.receive($0, hostTime: mach_absolute_time()) }
    }
}

@MainActor
private final class PrintPaster: DictationPaster {
    private(set) var last: String?

    func captureTarget() async -> (any Sendable)? { nil }

    func paste(_ text: String, into _: (any Sendable)?) async -> DictationPasteResult {
        last = text
        return .pasted
    }
}
