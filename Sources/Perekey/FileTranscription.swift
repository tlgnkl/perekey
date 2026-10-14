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
    private(set) var queue: FileTranscriber?
    private let models: VoiceModelsController
    private let modes: VoiceModesStore
    private let text: VoiceTextController

    init(models: VoiceModelsController, modes: VoiceModesStore, text: VoiceTextController) {
        self.models = models
        self.modes = modes
        self.text = text
    }

    /// Something is queued or running: Sparkle waits with the relaunch.
    var isBusy: Bool { queue?.isBusy ?? false }

    /// Voice came on: the queue starts and goes on with what a quit cut off.
    func start() {
        guard queue == nil else { return }
        let store = models.store
        let modes = self.modes
        let text = self.text
        let opener = VoiceAudioOpener()
        let queue = FileTranscriber(environment: FileTranscriber.Environment(
            folder: folder, opener: opener, detector: SileroVAD(store: store),
            makeEngine: { id in VoiceSetup.cloudEngine(id, modes: modes) ?? VoiceEngines.make(model: id, store: store) },
            makeDiarizer: { VBxDiarizer(store: store, opener: opener) },
            dictation: dictation,
            prompt: {
                await MainActor.run {
                    let prompt = TextRules.whisperPrompt(dictionary: text.text.settings.dictionary)
                    return prompt.isEmpty ? nil : prompt
                }
            }))
        self.queue = queue
        Task { await queue.resumePending() }
    }

    /// Voice went off: the work stops; what is done stays for next time.
    func stop() {
        guard let queue else { return }
        self.queue = nil
        Task { await queue.shutdown() }
    }

    /// «Расшифровать файл…»: the open panel, then the queue.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.message = voiceString("Choose audio or video to transcribe. Perekey reads the file and does not copy it.")
        panel.prompt = voiceString("Transcribe")
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.transcribe(panel.urls) }
        }
    }

    /// Files dropped on the menu bar item: those that are audio or video.
    /// False if none is, so the drop is refused.
    @discardableResult
    func transcribe(_ urls: [URL]) -> Bool {
        let files = urls.filter(Self.accepts)
        guard let queue, !files.isEmpty else { return false }
        let settings = models.settings.settings
        let model = DictationPreferences(settings).modelID
        // Voices split when the diarizer is downloaded; the recordings window
        // gets its own switch.
        let diarize = models.statuses.contains { $0.id == VBxDiarizer.modelID && $0.state == .ready }
        for url in files {
            let meta = RecordingMeta.file(VoiceAudioOpener.reference(to: url))
            guard let id = try? folder.create(meta, excludedFromBackup: true) else { continue }
            Task { await queue.enqueue(TranscriptionJob(recording: id, model: model, diarize: diarize)) }
        }
        return true
    }

    /// Audio or video by its type: what AVFoundation reads.
    nonisolated static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
#endif
