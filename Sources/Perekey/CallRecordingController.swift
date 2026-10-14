// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import Observation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore
import UserNotifications

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
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Shown in the panel after a recording stopped by itself.
    private(set) var notice: String?
    /// The capsule's ● and time; the menu bar sets it.
    @ObservationIgnored var indicator: CallIndicatorModel?
    /// A recording started or stopped: the Transcripts window reads the folder
    /// again, voice on or off.
    @ObservationIgnored var recordingsChanged: @MainActor () -> Void = {}

    /// The file queue while voice is on. It is made anew each time voice
    /// turns on, so it is read when a call stops, never kept.
    @ObservationIgnored var fileQueue: @MainActor () -> (any FileTranscribing)? = { nil }
    /// The model for files and calls: the user's choice for transcriptions,
    /// or the dictation model. A cloud one only if the user chose it; the
    /// queue asks for the consent to send a conversation itself.
    @ObservationIgnored var transcriptionModel: @MainActor () -> String = { VoiceSettings.defaultModel }

    init(capture: AudioCapture, settings: VoiceSettingsStore, isSupported: @escaping () -> Bool,
         folder: RecordingsFolder = RecordingsFolder())
    {
        self.capture = capture
        self.settings = settings
        self.isSupported = isSupported
        self.folder = folder
        // One stream: the snapshots arrive in the order the recorder sent them.
        let (statuses, sink) = AsyncStream.makeStream(of: CallRecorder.Status.self)
        recorder = CallRecorder(folder: folder, mic: capture, makeTap: CallRecorder.systemTap,
                                onStatus: { sink.yield($0) })
        statusTask = Task { [weak self] in
            for await status in statuses {
                self?.received(status)
            }
        }
        observe()
        // The recorder reads the queue at each «Стоп».
        let recorder = recorder
        let queue: @Sendable () async -> (any FileTranscribing)? = { [weak self] in await self?.currentQueue() }
        Task { await recorder.setTranscriber(queue) }
    }

    private func currentQueue() -> (any FileTranscribing)? {
        fileQueue()
    }

    private var managed: ManagedSettings { settings.managed }

    /// The menu item and the panel exist: voice is allowed and runs on this
    /// Mac, and no profile forbids call recording.
    var isAvailable: Bool {
        !managed.voiceDisabled && !managed.callRecordingDisabled && !settings.isLocked && isSupported()
    }

    var isRecording: Bool { status.phase != .idle }

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
        notice = nil
        refreshApps()
        if case let .app(id) = choice, !apps.contains(where: { $0.bundleID == id }) {
            choice = apps.first(where: \.isPlaying).map { .app($0.bundleID) } ?? .system
        }
        panelController().show()
    }

    func closePicker() {
        guard !isRecording else { return }
        notice = nil
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
        let retention = RecordingMeta.AudioRetention(
            rawValue: voice.effectiveCallAudioRetention(managed: managed).rawValue) ?? .always
        let options = CallRecorder.Options(
            source: source, retention: retention,
            excludedFromBackup: excludedFromBackup, model: transcriptionModel(), diarize: voice.callDiarize)
        problem = nil
        let capture = capture
        Task {
            do {
                // The first time, macOS asks for the microphone here.
                await capture.requestAccess()
                try await recorder.start(options)
                CallAnnouncement.post(voiceString("Call recording started"))
            } catch CallRecorder.StartError.cancelled {
                // «Стоп» came first: nothing to say.
            } catch let error as CallRecorder.StartError {
                problem = Self.message(error)
                panelController().show()
            } catch {
                problem = voiceString("The recording did not start.")
            }
        }
    }

    /// «Включать в Time Machine», unless a profile keeps recordings out.
    private var excludedFromBackup: Bool {
        !settings.settings.includesRecordingsInBackup(managed: managed)
    }

    /// The recording being written, from its folder's creation until it is
    /// stopped: the window and the audio's term leave it alone.
    var liveRecording: UUID? { recorder.liveRecording }

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
        guard let id = await recorder.stop(reason) else { return nil }
        if reason != .quit {
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
            recordingsChanged()
        } else if !isRecording, wasRecording {
            recordingsChanged()
            outputTimer?.invalidate()
            outputTimer = nil
            if status.lastStop == .limit {
                showLimitReached()
            } else {
                panel?.hide()
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

    /// The call may still go on: a line in the panel and a notification,
    /// and the focus stays where it is.
    private func showLimitReached() {
        let title = voiceString("The recording stopped at 4 hours")
        let body = voiceString("It is saved and goes to transcription. Start a new one to go on.")
        notice = title + ". " + body
        panelController().show()
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: "call-limit", content: content, trigger: nil))
        }
    }

    static func message(_ error: CallRecorder.StartError) -> String {
        switch error {
        case .alreadyRecording, .cancelled:
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
        watchQueue()
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
        let job = TranscriptionJob(recording: id, model: transcriptionModel(), diarize: voice.callDiarize)
        _ = try? folder.updateMeta(id) { $0.pendingJob = job }
        if let queue = fileQueue() {
            Task { await queue.enqueue(job) }
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
        let retention = RecordingMeta.AudioRetention(
            rawValue: settings.settings.effectiveCallAudioRetention(managed: managed).rawValue) ?? .always
        let policy = CallAudioPolicy(retention: retention, keepDisabled: managed.callAudioKeepDisabled)
        let folder = folder
        let active = liveRecording
        Task.detached(priority: .utility) {
            CallRecordings.removeExpiredAudio(in: folder, policy: policy, except: active)
        }
    }

    /// Voice turned on or off: the queue is another one.
    func queueChanged() {
        watchQueue()
    }

    /// A finished transcript may free its audio («удалять после расшифровки»).
    private func watchQueue() {
        phasesTask?.cancel()
        guard let queue = fileQueue() else { return }
        phasesTask = Task { [weak self] in
            var done: Set<UUID> = []
            for await phases in await queue.phases() {
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

/// Spoken by VoiceOver without moving its focus.
enum CallAnnouncement {
    @MainActor static func post(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
#endif
