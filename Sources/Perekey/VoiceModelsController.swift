// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import Observation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// The speech models for the rest of the app: owns the `VoiceModelStore`,
/// keeps what the Voice tab shows of it, and decides what `VoiceHTTP` may reach.
///
/// It lives as long as the app, not as long as the Settings window: a download
/// belongs to the store, and the tasks that start one are held here, so closing
/// the window ends neither.
@MainActor
@Observable
final class VoiceModelsController {
    let settings: VoiceSettingsStore
    let store: VoiceModelStore
    /// This Mac can run the models (Apple Silicon, macOS 15 or newer).
    let isSupported: Bool

    private(set) var statuses: [VoiceModelStatus] = []
    private(set) var usage: VoiceModelDiskUsage?
    /// Why the last action on a model failed, when the model's own status has
    /// no failure to show.
    private(set) var errors: [String: VoiceModelFailure] = [:]
    /// The input devices, as of the last look. CoreAudio is read when the tab
    /// opens and when the app comes to the front, not on every redraw.
    private(set) var microphones: [Microphone] = MicrophoneList.all()
    /// Why "Delete all" failed, in words for the person.
    private(set) var deleteAllError: String?
    /// What macOS does with its own shortcuts, as of the last look: read when
    /// the tab opens and when the app comes to the front, not on every redraw
    /// (it asks another process).
    private(set) var systemShortcuts = SystemShortcuts.current()
    /// Models "Delete all" kept because an engine holds them.
    private(set) var keptByDeleteAll: [String] = []
    /// The model picked in the list before it was on disk: it downloads and
    /// becomes the dictation model when ready. The current one works meanwhile.
    private(set) var pendingChoice: String?

    /// A download ended with the model ready. The dictation side warms the
    /// model up here.
    @ObservationIgnored var onModelReady: (@MainActor (String) -> Void)?

    /// The dictation modes: their servers on this Mac and those the user
    /// agreed to open the network for language models and cloud speech.
    @ObservationIgnored var modes: VoiceModesStore? {
        didSet {
            // The network stays closed until `start`, which applies it.
            modes?.observe { [weak self] in
                guard let self, watcher != nil else { return }
                applyNetwork()
            }
        }
    }

    @ObservationIgnored private let http: VoiceHTTP
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var usageSignature = ""

    init(settings: VoiceSettingsStore, isSupported: Bool = VoiceModelsController.hostIsSupported,
         store: VoiceModelStore? = nil, http: VoiceHTTP = .shared)
    {
        self.settings = settings
        self.isSupported = isSupported
        self.http = http
        self.store = store ?? VoiceModelStore(managed: settings.managed, http: http)
    }

    #if DEBUG
    /// For the settings snapshots: the given statuses, no store traffic, no network.
    init(preview settings: VoiceSettingsStore, statuses: [VoiceModelStatus], usage: VoiceModelDiskUsage?,
         isSupported: Bool = true)
    {
        self.settings = settings
        self.isSupported = isSupported
        http = VoiceHTTP()
        store = VoiceModelStore(
            locations: VoiceModelLocations(
                models: FileManager.default.temporaryDirectory.appending(path: "perekey-preview-models"),
                managed: URL(filePath: "/nonexistent/VoiceModels"),
                coreMLCache: FileManager.default.temporaryDirectory.appending(path: "perekey-preview-cache")),
            managed: settings.managed, http: http)
        self.statuses = statuses
        self.usage = usage
    }

    /// For the settings snapshots: a model picked while it downloads.
    func previewPending(_ id: String) { pendingChoice = id }
    #endif

    static var hostIsSupported: Bool {
        #if arch(arm64)
        VoiceHost.isSupported(isAppleSilicon: true,
                              osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        #else
        false
        #endif
    }

    /// Opens or closes the network with the settings, and follows the store.
    /// Called once at launch; the network is closed until then.
    func start() {
        guard watcher == nil else { return }
        settings.observe { [weak self] in self?.applyNetwork() }
        watcher = Task { [weak self, store] in
            for await list in await store.updates() {
                guard let self else { return }
                statuses = list
                refreshUsage(list)
            }
        }
    }

    /// Whether "Download" may start a download now.
    var canDownload: Bool { isSupported && settings.isOn && store.canDownload }

    /// The network is open for model downloads only while voice is on and no
    /// profile forbids it; turning voice off stops the running downloads.
    private func applyNetwork() {
        VoiceNetworkPolicy.apply(
            isEnabled: settings.settings.isEnabled, newerSchemaVersion: settings.settings.newerSchemaVersion,
            isSupported: isSupported, managed: settings.managed, modes: modes?.modes, to: http)
        if !http.allowed.contains(.modelDownload) {
            for id in downloads.keys { cancel(id) }
        }
    }

    /// The dictation model, from the list: a model on disk at once, another
    /// one after its download.
    func choose(_ id: String) {
        guard let status = statuses.first(where: { $0.id == id }) else { return }
        if status.state == .ready {
            pendingChoice = nil
            if settings.settings.model != id { settings.update { $0.model = id } }
            return
        }
        guard canDownload || status.isDownloading else { return }
        // A damaged model an engine holds is repaired when dictation is done, as its Repair says.
        if case .damaged = status.state, status.isInUse { return }
        // The chosen model that is not on disk yet only needs the files.
        pendingChoice = settings.settings.model == id ? nil : id
        if !status.isDownloading { download(id) }
    }

    func download(_ id: String) {
        guard canDownload, downloads[id] == nil else { return }
        errors[id] = nil
        downloads[id] = Task { [weak self, store] in
            do {
                try await store.download(id)
                if let self, pendingChoice == id {
                    pendingChoice = nil
                    settings.update { $0.model = id }
                }
                self?.onModelReady?(id)
            } catch is CancellationError {
                // `cancel` has dropped the pending choice. A pick made since then
                // found this task still running, so the download starts again here.
                self?.downloads[id] = nil
                if self?.pendingChoice == id { self?.download(id) }
                return
            } catch let failure as VoiceModelFailure {
                self?.errors[id] = failure
                self?.dropPending(id)
            } catch {
                self?.errors[id] = .network(error.localizedDescription)
                self?.dropPending(id)
            }
            self?.downloads[id] = nil
        }
    }

    private func dropPending(_ id: String) {
        if pendingChoice == id { pendingChoice = nil }
    }

    func cancel(_ id: String) {
        dropPending(id)
        Task { [store] in await store.cancelDownload(id) }
    }

    func delete(_ id: String) {
        errors[id] = nil
        Task { [weak self, store] in
            do { try await store.delete(id) } catch let failure as VoiceModelFailure { self?.errors[id] = failure } catch {}
            self?.refreshUsage(force: true)
        }
    }

    func deleteAll() {
        deleteAllError = nil
        Task { [weak self, store] in
            do {
                self?.keptByDeleteAll = try await store.deleteAll()
            } catch let failure as VoiceModelFailure {
                self?.deleteAllError = ModelFailureText.text(failure)
            } catch {
                self?.deleteAllError = error.localizedDescription
            }
            self?.refreshUsage(force: true)
        }
    }

    /// Re-reads the disk: the administrator may have put a model there.
    func refresh() {
        keptByDeleteAll = []
        deleteAllError = nil
        Task { [store] in await store.refresh() }
        refreshUsage(force: true)
    }

    func refreshMicrophones() {
        microphones = MicrophoneList.all()
        systemShortcuts = SystemShortcuts.current()
    }

    /// Opens the folder the models are read from in Finder.
    func revealFolder() {
        let managed = settings.managed.voiceModelDownloadsDisabled
        var url = managed ? store.locations.managed : store.locations.models
        if !managed { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(url)
    }

    /// The models' disk use changes when a state changes, not on every
    /// progress report.
    private func refreshUsage(_ list: [VoiceModelStatus]? = nil, force: Bool = false) {
        let signature = (list ?? statuses).map { "\($0.id):\(Self.kind(of: $0.state))" }.joined(separator: ",")
        guard force || signature != usageSignature else { return }
        usageSignature = signature
        Task { [weak self, store] in
            let usage = await store.diskUsage()
            self?.usage = usage
        }
    }

    private static func kind(of state: VoiceModelState) -> String {
        switch state {
        case .absent: "absent"
        case .partial: "partial"
        case .downloading: "downloading"
        case .waitingForNetwork: "waiting"
        case .ready: "ready"
        case .damaged: "damaged"
        }
    }
}

extension VoiceModelStatus {
    /// Bytes are coming, or wait for the network to come back.
    var isDownloading: Bool {
        switch state {
        case .downloading, .waitingForNetwork: true
        case .absent, .partial, .ready, .damaged: false
        }
    }
}
#endif
