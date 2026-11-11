// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// An error whose message holds the dictated words, as a model's may.
private enum LeakyError: Error, CustomStringConvertible {
    case words(String)
    var description: String {
        switch self {
        case let .words(text): "failed on \(text)"
        }
    }
}

/// A model that answers, fails, or is cancelled as the test says.
private actor ScriptedEngine: SpeechEngine {
    enum Behavior { case answer(String), fail(any Error) }

    nonisolated let id = "scripted"
    private let behavior: Behavior
    private(set) var heard: [Int] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    func prepare() async throws {}
    func unload() async {}

    func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        heard.append(audio.samples.count)
        switch behavior {
        case let .answer(text): return Transcript(text: text)
        case let .fail(error): throw error
        }
    }
}

struct SegmentedRecognizerTests {
    private static let second = Int(VoiceCore.sampleRate)

    private func recognizer(_ engine: ScriptedEngine, ready: Task<Void, any Error> = Task {}) -> SegmentedRecognizer {
        let audio = DictationAudio(seconds: 30)
        let samples = [Float](repeating: 0.5, count: 12 * Self.second)
        samples.withUnsafeBufferPointer { audio.receive($0, hostTime: 1) }
        return SegmentedRecognizer(audio: audio, engine: engine, detector: nil, dictionary: nil, hint: nil,
                                   promptWords: 12, ready: ready, log: Logger(subsystem: "app.perekey", category: "test"))
    }

    @Test func aFailedPieceIsLoggedByItsTypeAndNotByItsText() async throws {
        let engine = ScriptedEngine(.fail(LeakyError.words("секретные слова диктовки")))
        let pieces = recognizer(engine)
        await pieces.add(0..<(5 * Self.second))
        #expect(try await pieces.finish(upTo: 5 * Self.second) == nil, "the whole recording is recognized instead")
        let failure = try #require(await pieces.failure)
        #expect(failure.contains("LeakyError"))
        #expect(!failure.contains("секретные"), "the message may hold the dictation")
        #expect(!failure.contains("failed on"))
    }

    @Test func aCancelledPieceIsNotAFailure() async {
        let engine = ScriptedEngine(.fail(CancellationError()))
        let pieces = recognizer(engine)
        await pieces.add(0..<(5 * Self.second))
        await #expect(throws: CancellationError.self) { try await pieces.finish(upTo: 5 * Self.second) }
        #expect(await pieces.failure == nil, "not marked as a failure")
    }

    @Test func aCancelledModelLoadIsNotAFailure() async {
        let engine = ScriptedEngine(.answer("Один."))
        let loading = Task<Void, any Error> { throw CancellationError() }
        let pieces = recognizer(engine, ready: loading)
        await pieces.add(0..<(5 * Self.second))
        await #expect(throws: CancellationError.self) { try await pieces.finish(upTo: 5 * Self.second) }
        #expect(await pieces.failure == nil)
        #expect(await engine.heard.isEmpty)
    }

    @Test func aFailedModelLoadFailsThePiecesAndLogsItsType() async throws {
        let engine = ScriptedEngine(.answer("Один."))
        let loading = Task<Void, any Error> { throw LeakyError.words("слова") }
        let pieces = recognizer(engine, ready: loading)
        await pieces.add(0..<(5 * Self.second))
        #expect(try await pieces.finish(upTo: 5 * Self.second) == nil)
        #expect(try #require(await pieces.failure).contains("LeakyError"))
        #expect(await engine.heard.isEmpty)
    }

    @Test func cancelTakesEffectAtOnceFromOutsideTheActor() async {
        let engine = ScriptedEngine(.answer("Один."))
        let pieces = recognizer(engine)
        // No await between the cancel and the piece that follows it.
        pieces.cancel()
        await pieces.add(0..<(5 * Self.second))
        await pieces.idle()
        #expect(await engine.heard.isEmpty, "no piece starts after the cancel")
        await #expect(throws: CancellationError.self) { try await pieces.finish(upTo: 5 * Self.second) }
    }
}
