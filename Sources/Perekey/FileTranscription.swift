// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyVoice
import PerekeyVoiceCore
import UniformTypeIdentifiers

/// Files into the transcription queue: «Расшифровать файл…» in the menu
/// and a file dropped on the menu bar item. The queue runs while voice is
/// on; with voice off nothing loads and nothing is queued. The recordings
/// window shows what comes of it (`FileTranscriber.phases`).
@MainActor
final class FileTranscription {
    /// Dictation reports here; the queue waits for it between windows.
    let dictation = DictationActivity()
    let folder = RecordingsFolder()
    private let opener = VoiceAudioOpener()
    private let models: VoiceModelsController
    private let modes: VoiceModesStore
    private let text: VoiceTextController
    private lazy var lifecycle = FileQueueLifecycle(environment: { [unowned self] in environment() },
                                                    clean: { [opener] in opener.clearScratch(before: $0) })

    init(models: VoiceModelsController, modes: VoiceModesStore, text: VoiceTextController) {
        self.models = models
        self.modes = modes
        self.text = text
    }

    /// The recordings window follows the queue, which is made anew each time voice turns on.
    var queueChanged: ((FileTranscriber?) -> Void)?
    /// Others that follow it too: the call recorder.
    private var queueObservers: [(FileTranscriber?) -> Void] = []

    func observeQueue(_ observer: @escaping (FileTranscriber?) -> Void) {
        queueObservers.append(observer)
    }

    private func announceQueue() {
        queueChanged?(queue)
        for observer in queueObservers {
            observer(queue)
        }
    }

    /// The queue while voice is on.
    var queue: FileTranscriber? { lifecycle.queue }

    /// Something is queued or running: Sparkle waits with the relaunch.
    var isBusy: Bool { queue?.isBusy ?? false }

    /// Voice came on: the queue starts and, once an old one has let go,
    /// goes on with what a quit cut off.
    func start() {
        lifecycle.start()
        announceQueue()
    }

    /// Voice went off: the work stops; what is done stays for next time.
    func stop() {
        lifecycle.stop()
        announceQueue()
    }

    private func environment() -> FileTranscriber.Environment {
        let store = models.store
        let modes = self.modes
        let text = self.text
        return FileTranscriber.Environment(
            folder: folder, opener: opener, detector: SileroVAD(store: store),
            makeEngine: { id in VoiceSetup.cloudEngine(id, modes: modes) ?? VoiceEngines.make(model: id, store: store) },
            makeDiarizer: { VBxDiarizer(store: store) },
            dictation: dictation,
            prompt: {
                await MainActor.run {
                    let prompt = TextRules.whisperPrompt(dictionary: text.text.settings.dictionary)
                    return prompt.isEmpty ? nil : prompt
                }
            },
            mayUpload: { id in await MainActor.run { modes.mayUploadConversation(model: id) } })
    }

    /// The model for files and calls: the user's choice for transcriptions,
    /// or the dictation model on this Mac.
    var model: String {
        let settings = models.settings.settings
        return TranscriptionModel.resolve(chosen: settings.transcriptionModel, dictation: settings.model)
    }

    /// «Расшифровать файл…»: the open panel, then the queue.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
            // Matroska has no type of its own on macOS: by extension.
            + ["mkv", "mka"].compactMap { UTType(filenameExtension: $0) }
        panel.message = voiceString("Choose audio or video to transcribe. Perekey reads the file and does not copy it.")
        panel.prompt = voiceString("Transcribe")
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.transcribe(panel.urls) }
        }
    }

    /// Files dropped on the menu bar item: those that are audio or video.
    /// False if none is, or voice is off, so the drop is refused.
    @discardableResult
    func transcribe(_ urls: [URL]) -> Bool {
        let files = urls.filter(Self.accepts)
        guard let queue, !files.isEmpty else { return false }
        let model = self.model
        // Voices split when the diarizer is downloaded; the recordings window
        // gets its own switch.
        let diarize = models.statuses.contains { $0.id == VBxDiarizer.modelID && $0.state == .ready }
        var jobs: [TranscriptionJob] = []
        for url in files {
            let meta = RecordingMeta.file(VoiceAudioOpener.reference(to: url))
            guard let id = try? folder.create(meta, excludedFromBackup: true) else { continue }
            jobs.append(TranscriptionJob(recording: id, model: model, diarize: diarize))
        }
        // One task, so the files go in the order they came.
        Task {
            for job in jobs { await queue.enqueue(job) }
        }
        return true
    }

    /// Whether a dragged file would be taken now.
    func acceptsDrop(_ url: URL) -> Bool {
        queue != nil && Self.accepts(url)
    }

    /// Audio or video by its type, and Matroska by its extension (mkv and mka
    /// are no type to macOS). Perekey reads most of it; the rest fails with the
    /// name of its format.
    nonisolated static func accepts(_ url: URL) -> Bool {
        if url.isFileURL, MatroskaFile.hasExtension(url) { return true }
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
#endif
