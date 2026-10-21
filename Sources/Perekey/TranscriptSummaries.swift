// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import Foundation
import Observation
import os
import PerekeyVoice
import PerekeyVoiceCore

/// «Конспект» and «Протокол встречи» of the «Расшифровки» window: one run per
/// recording at a time, off the main thread, with its progress, a stop, and
/// the answer saved in the recording's folder. The model is the one of the
/// setting, or a local one of the modes; the cloud only when the user chose
/// it, and with the consent to send it transcripts, asked again before every
/// request. Logs carry no text of a transcript or an answer.
@MainActor
@Observable
final class TranscriptSummaries {
    struct Running: Equatable {
        var action: TranscriptAction
        var progress: SummaryProgress
    }

    private(set) var running: [UUID: Running] = [:]
    /// Why the last run of a recording failed, until the next one.
    private(set) var failures: [UUID: SummaryFailure] = [:]

    /// A run saved its answer.
    @ObservationIgnored var finished: @MainActor (UUID, TranscriptAction) -> Void = { _, _ in }
    /// Whether voice is on: the gate lets nothing out while it is off.
    @ObservationIgnored var voiceOn: @MainActor () -> Bool = { true }
    /// The model of a choice; a server of the modes in the app.
    @ObservationIgnored var makeModel: @MainActor (SummaryModelChoice, EndpointAddress, String?)
        -> (model: any SummaryLanguageModel, budget: SummaryBudget)

    let modes: VoiceModesStore
    let folder: RecordingsFolder
    @ObservationIgnored private var tasks: [UUID: (run: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var runs = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "summaries")

    init(modes: VoiceModesStore, folder: RecordingsFolder = RecordingsFolder()) {
        self.modes = modes
        self.folder = folder
        makeModel = { choice, address, key in
            let server = SummaryServer(model: choice.model, address: address, key: key)
            return (server, server.budget)
        }
    }

    /// What runs, and where: nil when no model is set and none of the modes runs on this Mac.
    var model: SummaryModelChoice? { modes.modes.summaryLanguageModel }

    /// Starts `action` on `document`. A model off this Mac asks for the
    /// consent first; refused, nothing is sent and the failure says so.
    func start(_ action: TranscriptAction, recording id: UUID, document: TranscriptDocument, labels: SpeakerLabels) {
        guard tasks[id] == nil else { return }
        failures[id] = nil
        do {
            try TranscriptSummarizer.check(document)
        } catch {
            failures[id] = error as? SummaryFailure ?? .empty
            return
        }
        guard voiceOn() else {
            failures[id] = .voiceOff
            return
        }
        var readiness = modes.summaryReadiness()
        if case let .needsConsent(choice, _, _) = readiness {
            guard modes.askConversationTextConsent(endpoint: choice.endpoint) else {
                failures[id] = .needsConsent
                return
            }
            readiness = modes.summaryReadiness()
        }
        guard case let .ready(choice, address) = readiness else {
            if case let .failed(failure) = readiness { failures[id] = failure } else { failures[id] = .needsConsent }
            return
        }
        let (model, budget) = makeModel(choice, address, modes.key(choice.endpoint))
        let endpoint = choice.endpoint
        let host = address.displayHost
        let summarizer = TranscriptSummarizer(model: model, budget: budget, mayContinue: { [modes] in
            await MainActor.run { modes.maySendConversationText(endpoint: endpoint) }
        }, host: host)
        // What the answer is made of: a later rename or a new transcript makes it stale.
        let revision = folder.transcriptRevision(id)
        let lines = TranscriptLines.of(document, labels: labels)
        let language = document.language
        let folder = folder
        let log = log
        running[id] = Running(action: action, progress: SummaryProgress(done: 0, total: 1))
        runs += 1
        let run = runs
        let task = Task { [weak self] in
            let started = ContinuousClock.now
            let failure: SummaryFailure?
            do {
                let text = try await summarizer.run(action, lines: lines, language: language) { progress in
                    Task { @MainActor in self?.advance(id, run: run, to: progress) }
                }
                try Task.checkCancellation()
                // «Остановить» pressed while the answer came: it is not saved.
                guard self?.tasks[id]?.run == run else { throw CancellationError() }
                try await Task.detached { try folder.saveNote(text, action, for: id, revision: revision) }.value
                failure = nil
                log.info("\(action.rawValue, privacy: .public) saved: \(lines.count) lines, \(started.duration(to: .now), privacy: .public)")
            } catch is CancellationError {
                failure = nil
            } catch let error as SummaryFailure {
                failure = await MainActor.run { [weak self] in
                    guard let self else { return error }
                    return error.resolvingBlock(voiceOn: voiceOn(), cloudDisabled: modes.cloudDisabled,
                                                maySend: modes.maySendConversationText(endpoint: endpoint), host: host)
                }
                log.error("\(action.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            } catch RecordingsFolder.FileError.missing {
                // Deleted while it ran: nothing to save it to.
                failure = nil
            } catch {
                failure = .storageFailed
                let error = error as NSError
                log.error("\(action.rawValue, privacy: .public) not saved: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            }
            // A run that was stopped, or replaced by a newer one, leaves the state alone.
            guard let self, tasks[id]?.run == run else { return }
            tasks[id] = nil
            running[id] = nil
            failures[id] = failure
            if failure == nil { finished(id, action) }
        }
        tasks[id] = (run, task)
    }

    private func advance(_ id: UUID, run: Int, to progress: SummaryProgress) {
        guard tasks[id]?.run == run, let current = running[id], progress.done >= current.progress.done else { return }
        running[id]?.progress = progress
    }

    /// Stops the run of `id`; what it had is dropped.
    func cancel(_ id: UUID) {
        tasks[id]?.task.cancel()
        tasks[id] = nil
        running[id] = nil
    }

    func dismissFailure(_ id: UUID) { failures[id] = nil }

}
#endif
