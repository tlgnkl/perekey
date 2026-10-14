// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import Observation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// A call recording in the app: the menu item, the panel, the capsule's
/// time, and what the Mac does around it. Sleep, a closed lid and another
/// user stop the recording and keep it; a locked screen does not. Quitting
/// waits for the open segments to close. The audio past its term goes at
/// launch and once a day.
@MainActor
@Observable
final class CallRecordingController {
    private(set) var status = CallRecorder.Status()
    /// Programs with sound, for the source picker.
    private(set) var apps: [CallSourceApp] = []
    var choice: CallSourceChoice = .system
    /// Why the last start failed, for the panel.
    private(set) var problem: String?
    private(set) var outputIsSpeakers = false
    /// The last device change, shown for a few seconds.
    private(set) var deviceChangedAt: Date?

    @ObservationIgnored let recorder: CallRecorder
    @ObservationIgnored private let capture: AudioCapture
    @ObservationIgnored private let settings: VoiceSettingsStore
    @ObservationIgnored private let isSupported: () -> Bool
    @ObservationIgnored let folder: RecordingsFolder
    @ObservationIgnored private var panel: CallPanelController?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastPurge: Date?
    @ObservationIgnored private var phasesTask: Task<Void, Never>?
    @ObservationIgnored private var outputTimer: Timer?
    /// The capsule's ● and time; the menu bar sets it.
    @ObservationIgnored var indicator: CallIndicatorModel?

    /// The file queue, once there is one: stopped calls go to it, and its
    /// work counts as busy for the updater.
    @ObservationIgnored var fileQueue: (any FileTranscribing)? {
        didSet {
            let queue = fileQueue
            Task { await recorder.setTranscriber(queue) }
            watchQueue()
        }
    }

    init(capture: AudioCapture, settings: VoiceSettingsStore, isSupported: @escaping () -> Bool,
         folder: RecordingsFolder = RecordingsFolder())
    {
        self.capture = capture
        self.settings = settings
        self.isSupported = isSupported
        self.folder = folder
        let relay = StatusRelay()
        recorder = CallRecorder(folder: folder, mic: capture, makeTap: CallRecorder.systemTap,
                                onStatus: { relay.send($0) })
        relay.target = { [weak self] status in
            Task { @MainActor in self?.received(status) }
        }
        observe()
    }

    private var managed: ManagedSettings { settings.managed }

    /// The menu item and the panel exist: voice is allowed and runs on this
    /// Mac, and no profile forbids call recording.
    var isAvailable: Bool {
        !managed.voiceDisabled && !managed.callRecordingDisabled && !settings.isLocked && isSupported()
    }

    var isRecording: Bool { status.phase != .idle }

    /// A relaunch would cut work off: a call is recorded or transcribed.
    var isBusy: Bool { isRecording || fileQueue?.isBusy == true }

    // MARK: Menu and panel

    /// «Записать созвон» opens the panel to pick the source; «Остановить
    /// запись» stops.
    func menuAction() {
        if isRecording {
            stop()
        } else {
            showPicker()
        }
    }

    func showPicker() {
        guard isAvailable, !isRecording else { return }
        problem = nil
        refreshApps()
        if case let .app(id) = choice, !apps.contains(where: { $0.bundleID == id }) {
            choice = apps.first(where: \.isPlaying).map { .app($0.bundleID) } ?? .system
        }
        panelController().show()
    }

    func closePicker() {
        guard !isRecording else { return }
        panel?.hide()
    }

    func refreshApps() {
        apps = CallSourceApp.running()
    }

    /// Starts with the chosen source. The first time, a note on the other
    /// side's consent comes first.
    func start() {
        guard isAvailable, !isRecording else { return }
        guard askConsentOnce() else { return }
        let source: CallRecorder.Source = switch choice {
        case .system: .system
        case let .app(bundleID):
            .app(bundleID: bundleID, name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID)
        }
        let voice = settings.settings
        let retention = RecordingMeta.AudioRetention(rawValue: voice.callAudioRetention.rawValue) ?? .always
        let options = CallRecorder.Options(
            source: source, retention: managed.callAudioKeepDisabled ? .untilTranscribed : retention,
            excludedFromBackup: excludedFromBackup, model: voice.model, diarize: voice.callDiarize)
        problem = nil
        let capture = capture
        Task {
            do {
                // The first time, macOS asks for the microphone here.
                await capture.requestAccess()
                try await recorder.start(options)
                CallAnnouncement.post(voiceString("Call recording started"))
            } catch let error as CallRecorder.StartError {
                problem = Self.message(error)
                panelController().show()
            } catch {
                problem = voiceString("The recording did not start.")
            }
        }
    }

    /// The user's Time Machine choice as the folder holds it; a new folder
    /// stays out of the backups.
    private var excludedFromBackup: Bool {
        FileManager.default.fileExists(atPath: folder.root.path) ? folder.isExcludedFromBackup : true
    }

    func togglePause() {
        Task {
            if status.phase == .paused {
                await recorder.resume()
            } else {
                await recorder.pause()
            }
        }
    }

    func stop(_ reason: CallRecorder.StopReason = .user) {
        Task { await stopAndWait(reason) }
    }

    @discardableResult
    func stopAndWait(_ reason: CallRecorder.StopReason) async -> UUID? {
        let id = await recorder.stop(reason)
        if id != nil, reason != .quit {
            CallAnnouncement.post(voiceString("Call recording stopped"))
        }
        return id
    }

    func openPrivacySettings() {
        let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func panelController() -> CallPanelController {
        if let panel { return panel }
        let panel = CallPanelController(model: self)
        self.panel = panel
        return panel
    }

    private func received(_ status: CallRecorder.Status) {
        if status.deviceChanges > self.status.deviceChanges {
            deviceChangedAt = Date()
        }
        let wasRecording = isRecording
        self.status = status
        indicator?.timeline = status.phase == .idle ? nil : status.timeline
        indicator?.paused = status.phase == .paused
        if isRecording, !wasRecording {
            outputIsSpeakers = AudioOutput.isBuiltInSpeakers
            outputTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputIsSpeakers = AudioOutput.isBuiltInSpeakers }
            }
            panelController().show()
        } else if !isRecording, wasRecording {
            outputTimer?.invalidate()
            outputTimer = nil
            panel?.hide()
            if status.lastStop == .limit {
                showLimitReached()
            }
        }
    }

    // MARK: Consent

    /// «Во многих странах…», once. False if the user cancels.
    private func askConsentOnce() -> Bool {
        guard !settings.settings.callConsentShown else { return true }
        let alert = NSAlert()
        alert.messageText = voiceString("Warn the other side")
        alert.informativeText = voiceString(
            "In many countries, recording a conversation needs the consent of the people in it. Warn them.")
        alert.addButton(withTitle: voiceString("Record"))
        alert.addButton(withTitle: voiceString("Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        settings.update { $0.callConsentShown = true }
        return true
    }

    private func showLimitReached() {
        let alert = NSAlert()
        alert.messageText = voiceString("The recording stopped at 4 hours")
        alert.informativeText = voiceString("It is saved and goes to transcription. Start a new one to go on.")
        alert.addButton(withTitle: voiceString("OK"))
        NSApp.activate()
        alert.runModal()
    }

    static func message(_ error: CallRecorder.StartError) -> String {
        switch error {
        case .alreadyRecording:
            voiceString("A call is being recorded already.")
        case let .lowDiskSpace(free):
            voiceString("Not enough space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free, the recording needs 2 GB.")
        case .microphone:
            voiceString("The microphone did not start. Check it in System Settings → Privacy & Security → Microphone.")
        case .folder:
            voiceString("Perekey could not create the recording's folder.")
        }
    }

    // MARK: Launch, sleep, quit

    /// At launch: a call a crash cut off is closed and offered for
    /// transcription; the audio past its term goes.
    func launched() {
        let interrupted = CallRecordings.recoverInterrupted(in: folder)
        purge()
        guard isAvailable, let last = interrupted.last else { return }
        offerTranscription(of: last, count: interrupted.count)
    }

    private func offerTranscription(of id: UUID, count: Int) {
        let alert = NSAlert()
        alert.messageText = voiceString("A call recording was cut off")
        alert.informativeText = voiceString(
            "Perekey closed while it recorded. What reached the disk is saved: all but the last few minutes at most.")
        alert.addButton(withTitle: voiceString("Transcribe"))
        alert.addButton(withTitle: voiceString("Later"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let voice = settings.settings
        let job = TranscriptionJob(recording: id, model: voice.model, diarize: voice.callDiarize)
        _ = try? folder.updateMeta(id) { $0.pendingJob = job }
        if let fileQueue {
            Task { await fileQueue.enqueue(job) }
        }
    }

    /// Cleans by the term when a day has passed since the last time: at
    /// launch, when the menu opens, after a transcription.
    func purgeIfDue() {
        guard let lastPurge, Date().timeIntervalSince(lastPurge) < 24 * 3600, Date() >= lastPurge else {
            purge()
            return
        }
    }

    private func purge() {
        lastPurge = Date()
        let retention = RecordingMeta.AudioRetention(rawValue: settings.settings.callAudioRetention.rawValue) ?? .always
        let policy = CallAudioPolicy(retention: retention, keepDisabled: managed.callAudioKeepDisabled)
        let folder = folder
        let active = status.recording
        Task.detached(priority: .utility) {
            CallRecordings.removeExpiredAudio(in: folder, policy: policy, except: active)
        }
    }

    /// A finished transcript may free its audio («удалять после расшифровки»).
    private func watchQueue() {
        phasesTask?.cancel()
        guard let fileQueue else { return }
        phasesTask = Task { [weak self] in
            var done: Set<UUID> = []
            for await phases in fileQueue.phases() {
                let finished = Set(phases.filter { if case .done = $0.value { true } else { false } }.keys)
                if !finished.subtracting(done).isEmpty {
                    self?.purge()
                }
                done = finished
            }
        }
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        // The lid closed or the Mac goes to sleep: the recording ends and stays.
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopForSystem(.sleep) }
            })
        // Another user took the screen. A locked screen is not this: a call
        // goes on with the screen locked.
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopForSystem(.userSwitch) }
            })
    }

    private func stopForSystem(_ reason: CallRecorder.StopReason) {
        guard isRecording else { return }
        stop(reason)
    }

    /// ⌘Q, logout, an update's relaunch: while a call is recorded, Perekey
    /// quits once its segments are closed and `meta.json` is written.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        Task {
            // A hung tap does not hold the quit: the stop waits for it 2 s at most.
            _ = await stopAndWait(.quit)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The source in the picker.
enum CallSourceChoice: Hashable {
    case app(String)
    case system
}

/// Hands the recorder's status to the controller made after it.
private final class StatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CallRecorder.Status) -> Void)?

    var target: (@Sendable (CallRecorder.Status) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func send(_ status: CallRecorder.Status) {
        target?(status)
    }
}

/// Spoken by VoiceOver without moving its focus.
enum CallAnnouncement {
    @MainActor static func post(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
#endif
