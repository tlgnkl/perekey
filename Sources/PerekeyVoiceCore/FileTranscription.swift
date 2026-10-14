// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Splits one voice from another in long audio: «Спикер 1», «Спикер 2».
public protocol DiarizerEngine: VoiceModel {
    /// The `ModelCatalog` id of the model it runs.
    var id: String { get }
    /// Who speaks when, on the source's scale. Reads the audio from disk:
    /// four hours of floats in memory would take 0.9 GB.
    func diarize(_ source: AudioSource, progress: @escaping @Sendable (Double) -> Void) async throws
        -> [SpeakerTurn]
}

/// A stretch of one voice.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// The diarizer's cluster, from 0; numbers are not stable between runs.
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Whether the user dictates now: the one thing the file queue needs to know
/// about dictation. Dictation always starts at once on its own engine; the
/// queue stops at the next window's edge and goes on once the text is in.
/// The dictation controller reports, the file queue waits; neither knows the other.
public final class DictationActivity: Sendable {
    private struct State {
        var active = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Recording started.
    public func began() {
        state.withLock { $0.active = true }
    }

    /// The text is in, or the dictation ended without any. Call it on every
    /// way out of a session (a `defer` in the controller): a missed call
    /// leaves the file queue waiting for good.
    public func ended() {
        let waiters = state.withLock { state in
            state.active = false
            defer { state.waiters = [:] }
            return state.waiters.values
        }
        waiters.forEach { $0.resume() }
    }

    public var isActive: Bool { state.withLock(\.active) }

    /// Returns once no dictation runs: at once if none does, or once the
    /// waiting task is cancelled.
    public func idle() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    guard state.active, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }
}

/// A recording to transcribe: a file or a call, by its folder's id.
public struct TranscriptionJob: Codable, Sendable, Equatable {
    public var recording: UUID
    /// The `ModelCatalog` id, or a cloud model's id when the mode is a cloud one.
    public var model: String
    /// «Разделить по спикерам»: diarize the file, or a call's «Собеседники».
    public var diarize: Bool
    /// ISO 639-1; nil lets the model find it in the first window with speech.
    public var language: String?

    public init(recording: UUID, model: String, diarize: Bool, language: String? = nil) {
        self.recording = recording
        self.model = model
        self.diarize = diarize
        self.language = language
    }
}

/// Where a recording is in the queue.
public enum TranscriptionPhase: Sendable, Equatable {
    case queued
    /// The model loads and, the first time after an install or a macOS
    /// update, compiles for CoreML: minutes, shown as «Готовлю модель…», not 0 %.
    case preparingModel
    /// Share of all the work done, 0…1.
    case transcribing(Double)
    /// Stopped at a window's edge while the user dictates.
    case waitingForDictation(Double)
    case diarizing(Double)
    /// `transcript.json` is written.
    case done
    case failed(TranscriptionFailure)
    case cancelled

    /// Still in the queue or running.
    public var isPending: Bool {
        switch self {
        case .queued, .preparingModel, .transcribing, .waitingForDictation, .diarizing: true
        case .done, .failed, .cancelled: false
        }
    }
}

public enum TranscriptionFailure: Sendable, Equatable {
    /// The chosen file is gone, or the bookmark no longer opens it.
    case sourceMissing
    /// AVFoundation could not read it, or it has no audio.
    case unreadable
    /// The model is not downloaded, or the cloud is not allowed.
    case modelUnavailable
    /// The model failed on the audio.
    case engineFailed
    /// `meta.json` or `transcript.json` could not be read or written.
    case storageFailed
    /// A newer Perekey wrote `meta.json` or `transcript.json`: this one leaves them alone.
    case newerVersion
}

/// The file queue: what the recordings window and the call recorder use.
/// One recording runs at a time, in windows; between windows it yields to
/// dictation, checks for cancel and saves its progress.
public protocol FileTranscribing: Sendable {
    /// Queues a recording. Its folder must hold `meta.json`. A recording
    /// that already has a transcript gets a new one in its place
    /// («Расшифровать заново», with another model, say); one in the queue
    /// is queued again with the new job.
    func enqueue(_ job: TranscriptionJob) async
    /// Stops a recording's transcription, at the next window's edge if it
    /// runs. The old transcript, if any, stays.
    func cancel(_ recording: UUID) async
    /// The phase of every recording queued since launch, sent whole on
    /// each change, starting with the current one.
    func phases() -> AsyncStream<[UUID: TranscriptionPhase]>
    /// Something is queued or running: Sparkle waits with the relaunch.
    /// Any thread.
    var isBusy: Bool { get }
}
