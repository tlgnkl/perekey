// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import Observation
import os
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import UniformTypeIdentifiers

/// What the «Расшифровки» window holds: the list, the chosen recording's
/// transcript, the search, the queue's phases and the player. The work on
/// disk and in the queue is `TranscriptsLibrary`'s. Logs carry no text of any transcript.
@MainActor
@Observable
final class TranscriptsController {
    /// The chosen recording's transcript as the disk gave it.
    enum TranscriptState: Equatable {
        case none
        case loaded(TranscriptDocument)
        /// A newer Perekey wrote it: shown as unknown, never written.
        case newer
        case unreadable
    }

    /// A short message under the toolbar, in words of the window.
    enum Notice: Equatable {
        case sourceUnavailable(String)
        case nothingToPlay
        case noAudio
        case notMedia(String)
        case queueUnavailable
        case storageFailed
        case exportFailed
        case deleteAllFailed(Int)
        case recordingInProgress
        case deleteNotStopped
    }

    /// What the right side shows: the transcript, or what a model made of it.
    enum Pane: Hashable {
        case transcript
        case note(TranscriptAction)
    }

    private(set) var items: [RecordingItem] = []
    private(set) var transcript: TranscriptState = .none
    private(set) var phases: [UUID: TranscriptionPhase] = [:]
    private(set) var search = TranscriptSearch()
    private(set) var notice: Notice?
    /// Bytes recordings take on disk, as of the last look.
    private(set) var diskUsage: Int64 = 0
    /// The chosen recording's summary and minutes, as saved.
    private(set) var notes: [TranscriptAction: String] = [:]
    /// Those of `notes` made of an older transcript.
    private(set) var staleNotes: Set<TranscriptAction> = []
    var pane: Pane = .transcript
    var isDropTargeted = false
    let player = TranscriptPlayer()

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            player.stop()
            notice = nil
            pane = .transcript
            loadTranscript()
        }
    }

    var query = "" {
        didSet { refreshSearch() }
    }

    /// The file queue. Set by whoever owns it, again each time voice turns on or off;
    /// without it nothing is queued and a dropped file is refused.
    var queue: (any FileTranscribing)? {
        didSet {
            observeQueue()
            if queue == nil, !phases.isEmpty {
                phases = [:]
                reload()
            }
        }
    }

    let folder: RecordingsFolder
    let voice: VoiceSettingsStore
    /// The models «Расшифровать заново» can pick from; empty hides the menu.
    @ObservationIgnored var models: @MainActor () -> [(id: String, title: String)]
    /// The model for files and calls: the choice for transcriptions, or the dictation model.
    @ObservationIgnored var transcriptionModel: (@MainActor () -> String)?
    /// Asks, if the model is a cloud one, for the consent to send it a recording of a conversation.
    /// False: nothing is queued. A model of this Mac needs none.
    @ObservationIgnored var consent: @MainActor (String) -> Bool = { _ in true }
    /// Recordings a recorder is writing now. The call recorder wires this when it exists;
    /// until then `TranscriptsLibrary.resume` tells a recording that is going on by its `meta.json`.
    @ObservationIgnored var live: @MainActor () -> Set<UUID>

    /// «Конспект» and «Протокол встречи»; nil hides them.
    var summaries: TranscriptSummaries? {
        didSet {
            summaries?.finished = { [weak self] id, action in
                guard let self, selection == id else { return }
                loadTranscript()
                pane = .note(action)
            }
            // The queue lives while voice is on, and so does the network.
            summaries?.voiceOn = { [weak self] in self?.canQueue ?? false }
        }
    }

    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var reloads = 0
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "transcripts")

    init(folder: RecordingsFolder = RecordingsFolder(), queue: (any FileTranscribing)? = nil,
         voice: VoiceSettingsStore, models: @escaping @MainActor () -> [(id: String, title: String)] = { [] },
         live: @escaping @MainActor () -> Set<UUID> = { [] })
    {
        self.folder = folder
        self.queue = queue
        self.voice = voice
        self.models = models
        self.live = live
        observeQueue()
    }

    private var library: TranscriptsLibrary { TranscriptsLibrary(folder: folder, queue: queue) }

    var selected: RecordingItem? { items.first { $0.id == selection } }

    var document: TranscriptDocument? {
        if case let .loaded(document) = transcript { document } else { nil }
    }

    private var model: String { transcriptionModel?() ?? voice.settings.model }

    /// Dropped files and «Расшифровать заново» need the queue.
    var canQueue: Bool { queue != nil }

    // MARK: Loading

    /// Reads the list again, and the chosen transcript. When the window opens
    /// and when a recording changes state.
    func reload() {
        let library = library
        let phases = phases
        let live = live()
        reloads += 1
        let mine = reloads
        // Reading every `meta.json` is disk work: not on the main thread.
        Task {
            let loaded = await Task.detached { library.items(phases: phases, live: live) }.value
            guard mine == reloads else { return }
            items = loaded
            if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
            if selection == nil { selection = items.first?.id }
            loadTranscript()
            refreshUsage()
        }
    }

    func refreshUsage() {
        let root = folder.root
        Task {
            let bytes = await Task.detached { RecordingsDiskUsage.bytes(in: root) }.value
            diskUsage = bytes
        }
    }

    private func loadTranscript() {
        loading?.cancel()
        guard let id = selection else {
            transcript = .none
            notes = [:]
            staleNotes = []
            refreshSearch()
            return
        }
        let folder = folder
        loading = Task {
            let (loaded, notes, stale) = await Task.detached {
                (folder.transcript(id), folder.notes(of: id), folder.staleNotes(of: id))
            }.value
            guard !Task.isCancelled, selection == id else { return }
            self.notes = notes
            staleNotes = stale
            switch loaded {
            case .missing: transcript = .none
            case let .loaded(document): transcript = .loaded(document)
            case .newer: transcript = .newer
            case .unreadable: transcript = .unreadable
            }
            refreshSearch()
        }
    }

    // MARK: Queue

    private func observeQueue() {
        queueTask?.cancel()
        queueTask = nil
        guard let queue else { return }
        queueTask = Task { [weak self] in
            for await snapshot in await queue.phases() {
                guard let self else { return }
                apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: [UUID: TranscriptionPhase]) {
        let old = phases
        phases = snapshot
        // A new recording or a state that settled needs the disk; progress ticks do not.
        let changed = snapshot.contains { id, phase in
            guard let before = old[id] else { return true }
            return before.isPending != phase.isPending || (!phase.isPending && before != phase)
                || (phase == .queued && before != .queued)
        }
        if changed {
            reload()
        } else {
            let live = live()
            items = items.map { $0.with(phase: snapshot[$0.id], isLive: live.contains($0.id)) }
        }
    }

    func phase(of id: UUID) -> TranscriptionPhase? { phases[id] }

    // MARK: Search

    private func refreshSearch() {
        search.update(query: query, in: document?.segments ?? [])
    }

    func stepSearch(_ delta: Int) {
        if delta > 0 { search.next() } else { search.previous() }
    }

    // MARK: Speakers

    /// What a speaker is called here: the user's name or the label in the app's language.
    func name(of speaker: TranscriptSpeaker) -> String { labels.name(of: speaker) }

    var labels: SpeakerLabels {
        SpeakerLabels(me: voiceString("Me"), others: voiceString("Others"), speaker: { voiceString("Speaker \($0)") })
    }

    func rename(speaker: String, to name: String?) {
        guard let id = selection else { return }
        do {
            try library.rename(speaker: speaker, to: name, in: id)
            loadTranscript()
        } catch {
            fail(.storageFailed, error)
        }
    }

    // MARK: Actions

    /// «Расшифровать заново» with `model`, keeping whether speakers were told apart.
    func retranscribe(model: String) {
        guard let id = selection, consent(model) else { return }
        let diarize = document?.speakers.contains { $0.kind == .speaker } ?? false
        queueJob(id) { try await $0.retranscribe(id, model: model, diarize: diarize) }
    }

    /// «Расшифровать» on a recording the crash cut off, or one that failed.
    func resume(_ id: UUID) {
        let model = self.model
        guard consent(model) else { return }
        queueJob(id) { try await $0.resume(id, model: model, diarize: false) }
    }

    private func queueJob(_ id: UUID, _ job: @escaping @MainActor (TranscriptsLibrary) async throws -> Void) {
        let library = library
        Task {
            do {
                try await job(library)
                notice = nil
                reload()
            } catch TranscriptsLibraryError.queueUnavailable {
                notice = .queueUnavailable
            } catch TranscriptsLibraryError.recordingInProgress {
                notice = .recordingInProgress
            } catch {
                fail(.storageFailed, error)
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let queue else { return }
        Task { await queue.cancel(id) }
    }

    func delete(_ id: UUID) {
        let live = live()
        guard !live.contains(id) else {
            notice = .recordingInProgress
            return
        }
        let library = library
        let phase = phases[id]
        summaries?.cancel(id)
        Task {
            do {
                try await library.delete(id, phase: phase, live: live)
            } catch TranscriptsLibraryError.recordingInProgress {
                notice = .recordingInProgress
                return
            } catch TranscriptsLibraryError.cancelTimedOut {
                notice = .deleteNotStopped
                return
            } catch {
                fail(.storageFailed, error)
            }
            if selection == id { selection = nil }
            reload()
        }
    }

    /// «Удалить все записи» of the Voice tab.
    func deleteAll() {
        let library = library
        let phases = phases
        let live = live()
        for item in items where !live.contains(item.id) { summaries?.cancel(item.id) }
        Task {
            let failed = await library.deleteAll(phases: phases, live: live)
            selection = nil
            reload()
            if failed > 0 { notice = .deleteAllFailed(failed) }
        }
    }

    /// Audio and video files dropped on the window go into the queue.
    func drop(_ urls: [URL]) {
        guard canQueue else {
            notice = .queueUnavailable
            return
        }
        let library = library
        let model = self.model
        guard consent(model) else { return }
        let excluded = !voice.settings.includesRecordingsInBackup(managed: voice.managed)
        for url in urls {
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            guard url.isFileURL, type?.conforms(to: .audiovisualContent) == true else {
                notice = .notMedia(url.lastPathComponent)
                continue
            }
            Task {
                do {
                    let id = try await library.add(file: url, model: model, diarize: false, excludedFromBackup: excluded)
                    notice = nil
                    reload()
                    selection = id
                } catch TranscriptsLibraryError.queueUnavailable {
                    notice = .queueUnavailable
                } catch {
                    fail(.storageFailed, error)
                }
            }
        }
    }

    // MARK: Playback

    /// Plays the phrase `index` of the chosen transcript from its start.
    func play(segment index: Int) {
        guard let item = selected, item.capabilities.canPlay, let document, document.segments.indices.contains(index) else { return }
        let segment = document.segments[index]
        let kind = segment.speaker.flatMap { id in document.speakers.first { $0.id == id }?.kind }
        do {
            try player.play(item, in: folder, from: segment.start, speaker: kind)
            notice = nil
        } catch TranscriptPlayer.Failure.sourceUnavailable(let name) {
            notice = .sourceUnavailable(name)
        } catch TranscriptPlayer.Failure.nothingHere {
            notice = .nothingToPlay
        } catch {
            notice = .noAudio
        }
    }

    // MARK: Export

    func title(of item: RecordingItem) -> String {
        switch item.title {
        case let .file(name): name
        case let .app(name): voiceString("Call in \(name)")
        case .system: voiceString("Call")
        case .call: voiceString("Call")
        }
    }

    func text(_ format: TranscriptFormat) -> String? {
        guard let document, let item = selected else { return nil }
        return SubtitleWriter(document, labels: labels, title: title(of: item)).render(format)
    }

    func copyAll() {
        guard let text = text(.txt) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks for a place and writes the transcript there.
    func export(_ format: TranscriptFormat) {
        guard let item = selected, let text = text(format) else { return }
        let panel = NSSavePanel()
        let base = URL(fileURLWithPath: title(of: item)).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            notice = nil
        } catch {
            fail(.exportFailed, error)
        }
    }

    // MARK: Summaries

    /// Makes `action` of the chosen transcript; a saved one is replaced.
    func summarize(_ action: TranscriptAction) {
        guard let id = selection, let document, let summaries else { return }
        pane = .note(action)
        summaries.start(action, recording: id, document: document, labels: labels)
    }

    /// Too few words for a summary: the offer says so instead of the button.
    var isTooShortToSummarize: Bool {
        guard let document else { return false }
        return TranscriptLines.words(in: document) < TranscriptSummarizer.minimumWords
    }

    func copy(_ action: TranscriptAction) {
        guard let text = notes[action] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks for a place and writes the Markdown there.
    func export(_ action: TranscriptAction) {
        guard let item = selected, let text = notes[action] else { return }
        let panel = NSSavePanel()
        let base = URL(fileURLWithPath: title(of: item)).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) — \(action.title).md"
        if let type = UTType(filenameExtension: "md") { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            notice = nil
        } catch {
            fail(.exportFailed, error)
        }
    }

    // MARK: The Voice tab's «Записи»

    var callAudioRetention: CallAudioRetention {
        voice.settings.effectiveCallAudioRetention(managed: voice.managed)
    }

    func setCallAudioRetention(_ value: CallAudioRetention) {
        voice.update { $0.callAudioRetention = value }
    }

    var includesInBackup: Bool { voice.settings.includesRecordingsInBackup(managed: voice.managed) }

    func setIncludesInBackup(_ on: Bool) {
        voice.update { $0.includesRecordingsInBackup = on }
        do {
            try folder.setExcludedFromBackup(!includesInBackup)
        } catch {
            fail(.storageFailed, error)
        }
    }

    func showInFinder() {
        try? FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder.root)
    }

    // MARK: Errors

    private func fail(_ notice: Notice, _ error: any Error) {
        self.notice = notice
        // The domain and the code only: a path holds the user's name.
        let error = error as NSError
        log.error("Recordings: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    func dismissNotice() { notice = nil }
}
#endif
