// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import os
import PerekeyCore
import PerekeyVoiceCore

/// What the dictation HUD shows. The HUD reads `VoiceController.hud`, or
/// follows `hudUpdates()`.
public enum DictationHUDState: Hashable, Sendable {
    case hidden
    /// The hotkey was pressed; the microphone starts.
    case starting
    /// Updated about 20 times a second while recording.
    case recording(Recording)
    /// The model finishes its work. `preparingModel`: it is still loading
    /// ("Готовлю модель…"); the first time after login or an update CoreML
    /// compiles it.
    case recognizing(preparingModel: Bool)
    /// A hotkey press while recognizing: "Ещё распознаю".
    case stillRecognizing
    case pasting
    /// The text is in. A short confirmation, then hidden.
    case pasted
    /// The text was recognized but not pasted; it is in `last`.
    /// `NotPastedReason.offersPaste` says whether "Вставить" goes beside
    /// "Скопировать".
    case notPasted(NotPastedReason)
    /// No speech, or only phrases a model makes up out of silence.
    case nothingHeard
    case cancelled
    case failed(DictationFailure)

    public struct Recording: Hashable, Sendable {
        /// Seconds of audio so far.
        public var seconds: Double
        /// The loudness of the latest block, 0...1.
        public var level: Float
        /// The model is still loading; the audio waits for it.
        public var preparingModel: Bool

        public init(seconds: Double, level: Float, preparingModel: Bool) {
            self.seconds = seconds
            self.level = level
            self.preparingModel = preparingModel
        }
    }
}

public enum NotPastedReason: Hashable, Sendable {
    /// Another app, window or field is in front now.
    case targetChanged
    /// The caret is in a password field: "Курсор в поле пароля".
    case secureField
    /// Another app holds Secure Input; its name if known.
    case secureInput(owner: String?)
    /// Accessibility was revoked during the dictation.
    case noAccessibility
    /// The app did not answer in time; the text may still arrive.
    case timedOut
    case failed(String)

    /// Whether the HUD offers "Вставить" again. Not after a timeout (the
    /// first paste may still land: twice the text), nor into a password
    /// field, nor without Accessibility.
    public var offersPaste: Bool {
        switch self {
        case .targetChanged, .secureInput, .failed: true
        case .secureField, .noAccessibility, .timedOut: false
        }
    }
}

/// The latest recognized text and what came of it.
public struct DictatedText: Hashable, Sendable {
    public var text: String
    /// It went in.
    public var pasted: Bool
    /// It was meant for a password field or an app under Secure Input: it
    /// stays out of the history.
    public var isPrivate: Bool

    public init(text: String, pasted: Bool, isPrivate: Bool) {
        self.text = text
        self.pasted = pasted
        self.isPrivate = isPrivate
    }
}

public enum DictationFailure: Hashable, Sendable {
    /// No microphone permission: "Нет доступа к микрофону".
    case microphoneDenied
    case noMicrophone
    case microphone(String)
    /// The speech model is not downloaded or did not load.
    case model(String)
    case recognition(String)
}

/// Runs dictation: the voice hotkey (`Effect.voice`) goes into
/// `DictationMachine`, and its outputs come out here as the microphone,
/// the speech model, the paste and the HUD state. Main thread.
///
/// The audio of a session goes into a `DictationAudio` made at its start.
/// The model loads while the user speaks; recognition runs at
/// `userInitiated` once the recording stops. The model unloads after the
/// idle time of the settings (`ModelResidency`).
@MainActor
@Observable
public final class VoiceController {
    /// What the HUD shows now.
    public private(set) var hud: DictationHUDState = .hidden {
        didSet {
            guard hud != oldValue else { return }
            for observer in observers.values { observer.yield(hud) }
        }
    }

    /// The latest recognized text, pasted or not: for "Вставить · Скопировать"
    /// and, with stage 3, the history. Set once the paste has an answer.
    public private(set) var last: DictatedText?

    /// Things the controller asks of the app.
    public struct Hooks {
        /// Tell the event tap whether it takes Esc for a session
        /// (`InputEvent.voiceSession`).
        public var sessionChanged: @MainActor (Bool) -> Void
        /// Whether the hold trigger's keys are down now (`VoiceTrigger.isHeldNow`).
        public var holdIsDown: @MainActor () -> Bool
        /// The keys were found up: the tap ends the hold (`InputEvent.voiceHoldLost`).
        public var holdLost: @MainActor () -> Void
        /// After a paste: select the layout of the phrase's language.
        public var pasted: @MainActor (String) -> Void
        public var play: @MainActor (DictationMachine.Sound) -> Void

        public init(sessionChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                    holdIsDown: @escaping @MainActor () -> Bool = { true },
                    holdLost: @escaping @MainActor () -> Void = {},
                    pasted: @escaping @MainActor (String) -> Void = { _ in },
                    play: @escaping @MainActor (DictationMachine.Sound) -> Void = DictationSounds.play)
        {
            self.sessionChanged = sessionChanged
            self.holdIsDown = holdIsDown
            self.holdLost = holdLost
            self.pasted = pasted
            self.play = play
        }
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// A speech model and what keeps it in memory. One per model id, so a
    /// warm-up and dictation share the same copy.
    private struct Model {
        let engine: any SpeechEngine
        let residency: ModelResidency
    }

    @ObservationIgnored private var machine = DictationMachine()
    @ObservationIgnored private let microphone: any DictationMicrophone
    @ObservationIgnored private let paster: any DictationPaster
    @ObservationIgnored private let secureInput: (any DictationSecureInputRules)?
    @ObservationIgnored private let makeEngine: (String) -> (any SpeechEngine)?
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let limitSeconds: Int
    @ObservationIgnored private var preferences: DictationPreferences
    /// A microphone chosen during a session, applied once it is over.
    @ObservationIgnored private var pendingMicrophone: String??
    @ObservationIgnored private var models: [String: Model] = [:]
    @ObservationIgnored private let detector: (any SpeechDetector)?
    @ObservationIgnored private let detectorResidency: ModelResidency?
    @ObservationIgnored private var current: Work?
    /// How a session's recognition failed, for the HUD.
    @ObservationIgnored private var failure: (session: DictationMachine.Session, failure: DictationFailure)?
    @ObservationIgnored private var holdWatch: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: AsyncStream<DictationHUDState>.Continuation] = [:]
    @ObservationIgnored private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "voice")
    /// Recognitions over, whatever came of them: tests wait for it.
    @ObservationIgnored private(set) var recognitionsDone = 0

    /// One session's audio and the work on it. The model is the one the
    /// session started with: changing the setting mid-way does not swap it.
    private final class Work {
        let session: DictationMachine.Session
        let audio: DictationAudio
        let model: Model?
        var subscription: AudioSubscription?
        var target: Task<(any Sendable)?, Never>?
        /// The session's hold on the model, from `ModelResidency.begin`.
        var loading: Task<Void, any Error>?
        var modelReady = false
        /// The session's hold on the speech detector; true once it holds.
        var detecting: Task<Bool, Never>?
        var stopping: Task<Void, Never>?
        var ticker: Task<Void, Never>?
        var silence: Task<Void, Never>?
        var isRecognizing = false
        var isReleased = false

        init(session: DictationMachine.Session, audio: DictationAudio, model: Model?) {
            self.session = session
            self.audio = audio
            self.model = model
        }

        func stopTimers() {
            ticker?.cancel()
            silence?.cancel()
        }
    }

    /// - Parameter limitSeconds: the longest dictation (`DictationAudio.limitSeconds`).
    public init(preferences: DictationPreferences, microphone: any DictationMicrophone, paster: any DictationPaster,
                secureInput: (any DictationSecureInputRules)?, detector: (any SpeechDetector)?,
                makeEngine: @escaping (String) -> (any SpeechEngine)?, hooks: Hooks = Hooks(),
                limitSeconds: Int = DictationAudio.limitSeconds,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.preferences = preferences
        self.microphone = microphone
        self.paster = paster
        self.secureInput = secureInput
        self.detector = detector
        self.makeEngine = makeEngine
        self.hooks = hooks
        self.limitSeconds = limitSeconds
        self.sleep = sleep
        detectorResidency = detector.map { ModelResidency($0, unloadDelay: preferences.unloadAfter) }
        pendingMicrophone = .some(preferences.microphoneUID)
        applyMicrophone()
        secureInput?.onStop = { [weak self] in self?.handle(.secureInputChanged(true)) }
        secureInput?.onEscape = { [weak self] in self?.handle(.voice(.cancel)) }
    }

    /// The app's controller: the microphone, the store's models, and the
    /// system events that stop or cancel a recording.
    public convenience init(preferences: DictationPreferences, capture: AudioCapture, store: VoiceModelStore,
                            paster: any DictationPaster, secureInput: (any DictationSecureInputRules)?,
                            hooks: Hooks)
    {
        self.init(preferences: preferences, microphone: capture, paster: paster, secureInput: secureInput,
                  detector: SileroVAD(store: store), makeEngine: { VoiceEngines.make(model: $0, store: store) },
                  hooks: hooks)
        observeSystem()
    }

    // MARK: - Inputs

    /// The voice hotkey, from `EngineMessage.voice`.
    public func voice(_ signal: VoiceSignal) {
        guard !isShutDown else { return }
        if machine.state == .idle, signal == .toggle || signal == .holdBegan {
            // No app in front: nowhere to paste, so no recording.
            guard paster.hasTarget else { return }
            // Secure Input keeps dictation silent: no start, no HUD.
            let allowed = secureInput?.allowsStart ?? true
            if allowed == machine.secureInput { handle(.secureInputChanged(!allowed)) }
        }
        handle(.voice(signal))
    }

    /// Accessibility was revoked: a recording stops, its text is not pasted.
    public func accessibilityLost() {
        handle(.accessibilityLost)
    }

    public enum SystemEvent: Sendable {
        case sleep
        /// The screen locked, or another user took the console.
        case sessionLost
    }

    public func system(_ event: SystemEvent) {
        switch event {
        case .sleep: handle(.sleep)
        case .sessionLost: handle(.sessionLost)
        }
    }

    /// New preferences. A new model unloads the old one once no session
    /// uses it; a new microphone applies after the session in progress.
    public func apply(_ preferences: DictationPreferences) {
        let old = self.preferences
        self.preferences = preferences
        if preferences.modelID != old.modelID, let previous = models[old.modelID] {
            Task { await previous.residency.unload() }
        }
        if preferences.unloadAfter != old.unloadAfter {
            let delay = preferences.unloadAfter
            let residencies = models.values.map(\.residency) + [detectorResidency].compactMap { $0 }
            Task {
                for residency in residencies { await residency.setUnloadDelay(delay) }
            }
        }
        if preferences.microphoneUID != old.microphoneUID {
            pendingMicrophone = .some(preferences.microphoneUID)
            applyMicrophone()
        }
    }

    private func applyMicrophone() {
        guard machine.state == .idle, let uid = pendingMicrophone else { return }
        pendingMicrophone = nil
        let microphone = self.microphone
        Task { await microphone.select(uid) }
    }

    /// Loads a model in the background after its download, so that the
    /// first dictation does not wait for CoreML. It stays for the idle time,
    /// the same copy dictation then uses.
    public func warmUp(model id: String) async throws {
        guard let model = model(for: id) else { throw VoiceModelFailure.unknownModel(id) }
        try await model.residency.warmUp()
    }

    /// A download is over. Only the model dictation uses warms up: another
    /// one, downloaded to try, would stay held in memory and in the store
    /// until its timer, and could not be deleted meanwhile.
    public func modelDownloaded(_ id: String) async {
        guard id == preferences.modelID else { return }
        try? await warmUp(model: id)
    }

    /// Unloads the models as soon as no session uses them.
    public func unloadModels() async {
        for model in models.values {
            await model.residency.unload()
        }
        await detectorResidency?.unload()
    }

    /// Dictation is turned off: a session in progress is dropped, the tap
    /// gives Esc back, the observers go, `hudUpdates()` streams end, and the
    /// models unload. The controller takes no input after it.
    public func shutdown() async {
        guard !isShutDown else { return }
        handle(.shutdown)
        isShutDown = true
        holdWatch?.cancel()
        holdWatch = nil
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens = []
        secureInput?.onStop = nil
        secureInput?.onEscape = nil
        hud = .hidden
        for observer in observers.values {
            observer.finish()
        }
        observers = [:]
        await unloadModels()
    }

    /// The HUD state now and after every change.
    public func hudUpdates() -> AsyncStream<DictationHUDState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DictationHUDState.self, bufferingPolicy: .bufferingNewest(1))
        guard !isShutDown else {
            continuation.finish()
            return stream
        }
        let key = UUID()
        observers[key] = continuation
        continuation.yield(hud)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[key] = nil }
        }
        return stream
    }

    /// The machine's state, for tests and the debug snapshot.
    public var state: DictationMachine.State { machine.state }

    // MARK: - Machine

    private func handle(_ input: DictationMachine.Input) {
        for output in machine.handle(input) {
            perform(output)
        }
    }

    private func perform(_ output: DictationMachine.Output) {
        switch output {
        case let .startCapture(session):
            start(session)
        case let .stopCapture(session):
            stop(session)
        case let .discard(session):
            discard(session)
        case let .recognize(session, delivery):
            recognize(session, delivery)
        case let .paste(session, text):
            paste(session, text)
        case let .keep(_, text):
            last = DictatedText(text: text, pasted: false, isPrivate: false)
            hud = .notPasted(.noAccessibility)
        case let .takesEscape(on):
            hooks.sessionChanged(on)
        case let .sessionActive(on):
            if on {
                secureInput?.sessionBegan()
            } else {
                secureInput?.sessionEnded()
                if let work = current {
                    work.stopTimers()
                    release(work)
                }
                current = nil
                applyMicrophone()
            }
        case let .watchHold(on):
            watchHold(on)
        case let .sound(sound):
            if preferences.playsSounds { hooks.play(sound) }
        case let .phase(phase):
            show(phase)
        }
    }

    private func show(_ phase: DictationMachine.Phase) {
        switch phase {
        case .starting: hud = .starting
        case .recording: hud = .recording(recording)
        case .recognizing: hud = .recognizing(preparingModel: current?.modelReady == false)
        case .stillRecognizing: hud = .stillRecognizing
        case .pasting: hud = .pasting
        case .cancelled: hud = .cancelled
        case .nothingHeard: hud = .nothingHeard
        case .captureFailed(.notAuthorized): hud = .failed(.microphoneDenied)
        case .captureFailed(.noMicrophone): hud = .failed(.noMicrophone)
        case let .captureFailed(.other(message)): hud = .failed(.microphone(message))
        case let .recognitionFailed(message):
            let known = failure?.session == machine.lastSession ? failure?.failure : nil
            hud = .failed(known ?? .recognition(message))
            failure = nil
        }
    }

    private var recording: DictationHUDState.Recording {
        DictationHUDState.Recording(seconds: current?.audio.seconds ?? 0, level: min(1, (current?.audio.level ?? 0) * 4),
                                    preparingModel: current?.modelReady == false)
    }

    // MARK: - Session work

    private func model(for id: String) -> Model? {
        if let model = models[id] { return model }
        guard let engine = makeEngine(id) else { return nil }
        let model = Model(engine: engine, residency: ModelResidency(engine, unloadDelay: preferences.unloadAfter))
        models[id] = model
        return model
    }

    private func start(_ session: DictationMachine.Session) {
        let audio = DictationAudio(
            seconds: limitSeconds,
            onLimit: { [weak self] in
                Task { @MainActor in self?.handle(.captureEnded(session, .limit)) }
            },
            onInterruption: { [weak self] _ in
                // A new device, a lost one, a stall: what was said so far is recognized.
                Task { @MainActor in self?.handle(.captureEnded(session, .deviceChanged)) }
            })
        let work = Work(session: session, audio: audio, model: model(for: preferences.modelID))
        current?.stopTimers()
        current = work
        let paster = self.paster
        work.target = Task { await paster.captureTarget() }
        if let residency = work.model?.residency {
            work.loading = Task { [weak self, weak work] in
                try await residency.begin()
                work?.modelReady = true
                self?.refreshHUD()
            }
        }
        let microphone = self.microphone
        Task {
            do {
                let subscription = try await microphone.begin(audio)
                guard current === work else {
                    await microphone.end(subscription)
                    return
                }
                work.subscription = subscription
                handle(.captureStarted(session))
                if case .recording = machine.state { startTimers(work) }
            } catch {
                handle(.captureFailed(session, Self.failure(error)))
            }
        }
    }

    private func stop(_ session: DictationMachine.Session) {
        guard let work = current, work.session == session else { return }
        work.stopTimers()
        let microphone = self.microphone
        let subscription = work.subscription
        work.subscription = nil
        work.stopping = Task { if let subscription { await microphone.end(subscription) } }
    }

    private func discard(_ session: DictationMachine.Session) {
        guard let work = current, work.session == session else { return }
        stop(session)
        current = nil
        // A recognition under way keeps its hold on the model until it ends:
        // CoreML is not stopped half way, and the model must not go under it.
        if !work.isRecognizing { release(work) }
    }

    /// The session lets go of the model and the detector; their timers start.
    private func release(_ work: Work) {
        guard !work.isReleased else { return }
        work.isReleased = true
        let loading = work.loading
        let residency = work.model?.residency
        let detecting = work.detecting
        let detectorResidency = self.detectorResidency
        Task {
            if (try? await loading?.value) != nil { await residency?.end() }
            if await detecting?.value == true { await detectorResidency?.end() }
        }
    }

    /// The session's hold on the speech detector, taken once.
    private func detectorReady(_ work: Work) async -> Bool {
        guard let detectorResidency, !work.isReleased else { return false }
        if work.detecting == nil {
            work.detecting = Task { [log] in
                do {
                    try await detectorResidency.begin()
                    return true
                } catch {
                    log.error("speech detector: \(String(describing: error), privacy: .public)")
                    return false
                }
            }
        }
        return await work.detecting?.value ?? false
    }

    private func recognize(_ session: DictationMachine.Session, _: DictationMachine.Delivery) {
        guard let work = current, work.session == session else { return }
        work.isRecognizing = true
        let detector = self.detector
        Task(priority: .userInitiated) {
            await work.stopping?.value
            let audio = AudioBuffer16k(work.audio.samples)
            do {
                guard let engine = work.model?.engine, let loading = work.loading else {
                    throw VoiceModelFailure.unknownModel(preferences.modelID)
                }
                try await loading.value
                let detecting = await detectorReady(work) ? detector : nil
                let outcome = try await DictationRecognition.recognize(audio, engine: engine, detector: detecting)
                release(work)
                handle(.recognized(session, outcome))
            } catch {
                release(work)
                log.error("dictation: \(String(describing: error), privacy: .public)")
                let message = String(describing: error)
                failure = (session, work.modelReady ? .recognition(message) : .model(message))
                handle(.recognitionFailed(session, message))
            }
            recognitionsDone += 1
        }
    }

    private func paste(_ session: DictationMachine.Session, _ text: String) {
        let target = current?.session == session ? current?.target : nil
        let paster = self.paster
        Task {
            let result = await paster.paste(text, into: await target?.value)
            let reason: NotPastedReason? = switch result {
            case .pasted: nil
            case .targetChanged: .targetChanged
            case .secureField: .secureField
            case let .secureInput(owner): .secureInput(owner: owner)
            case .timedOut: .timedOut
            case let .failed(message): .failed(message)
            }
            // Dictation went off during the paste: no HUD, no layout switch.
            guard !isShutDown else { return }
            let isPrivate = reason == .secureField || { if case .secureInput = reason { true } else { false } }()
            last = DictatedText(text: text, pasted: reason == nil, isPrivate: isPrivate)
            if let reason {
                hud = .notPasted(reason)
            } else {
                hud = .pasted
                if preferences.switchesLayout { hooks.pasted(text) }
            }
            handle(.pasted(session))
        }
    }

    /// The level and the timer while recording, and the silence check.
    private func startTimers(_ work: Work) {
        let sleep = self.sleep
        work.ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(50)) } catch { return }
                self?.refreshHUD()
            }
        }
        guard let silenceStop = preferences.silenceStop, let detector else { return }
        let limit = silenceStop.components
        var watch = SilenceWatch(limit: Double(limit.seconds) + Double(limit.attoseconds) / 1e18)
        let session = work.session
        let audio = work.audio
        work.silence = Task { [weak self] in
            guard let self, await detectorReady(work) else { return }
            let chunk = VoiceActivity.chunk
            var checked = 0
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(500)) } catch { return }
                let heard = audio.count / chunk * chunk
                guard heard > checked else { continue }
                // One chunk before the new ones, so the detector has context.
                let samples = audio.samples(in: max(0, checked - chunk)..<heard)
                guard let probabilities = try? await detector.speechProbabilities(samples) else { return }
                let fresh = probabilities.suffix((heard - checked) / chunk)
                for (index, probability) in fresh.enumerated() {
                    let end = Double(checked + (index + 1) * chunk) / VoiceCore.sampleRate
                    if watch.observe(speech: probability >= VoiceActivity.threshold, upTo: end) {
                        handle(.captureEnded(session, .silence))
                        return
                    }
                }
                checked = heard
            }
        }
    }

    private func refreshHUD() {
        switch hud {
        case .recording: hud = .recording(recording)
        case .recognizing: hud = .recognizing(preparingModel: current?.modelReady == false)
        default: break
        }
    }

    /// While a hold session records, its keys are checked four times a
    /// second: a lost key up must not leave the microphone on.
    private func watchHold(_ on: Bool) {
        holdWatch?.cancel()
        holdWatch = nil
        guard on else { return }
        let sleep = self.sleep
        holdWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(.milliseconds(250)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                if !hooks.holdIsDown() {
                    hooks.holdLost()
                    return
                }
            }
        }
    }

    /// Whether the hold watch runs, for tests.
    var isWatchingHold: Bool { holdWatch != nil }

    private static func failure(_ error: any Error) -> DictationMachine.CaptureFailure {
        switch error as? AudioCaptureError {
        case .notAuthorized: .notAuthorized
        case .noInputDevice: .noMicrophone
        case let .engine(message): .other(message)
        case nil: .other(String(describing: error))
        }
    }

    // MARK: - System

    /// Sleep cancels a recording; a locked screen or another user at the
    /// console stops it and recognizes what was said.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
            tokens.append((center, token))
        }
        on(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.system(.sleep) }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.system(.sessionLost) }
        on(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.system(.sessionLost)
        }
    }
}

/// The start and stop sounds: system ones, off in the settings.
@MainActor
public enum DictationSounds {
    private static var playing: NSSound?

    public static func play(_ sound: DictationMachine.Sound) {
        let name = switch sound {
        case .start: "Tink"
        case .stop: "Pop"
        }
        guard let sound = NSSound(named: name) else { return }
        playing?.stop()
        playing = sound
        sound.play()
    }
}
