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
    /// The text was recognized but not pasted; it is in `lastText`, for
    /// "Вставить · Скопировать".
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
    /// The caret is in a password field, or Secure Input is on.
    case secureField
    /// Accessibility was revoked during the dictation.
    case noAccessibility
    case failed(String)
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
    /// and, with stage 3, the history.
    public private(set) var lastText: String?
    /// Whether `lastText` went in.
    public private(set) var lastTextPasted = false

    /// Things the controller asks of the app.
    public struct Hooks {
        /// Tell the event tap a session is on: Esc then cancels it
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

    @ObservationIgnored private var machine = DictationMachine()
    @ObservationIgnored private let microphone: any DictationMicrophone
    @ObservationIgnored private let paster: any DictationPaster
    @ObservationIgnored private let secureInput: (any DictationSecureInputRules)?
    @ObservationIgnored private let makeEngine: (String) -> (any SpeechEngine)?
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var settings: VoiceSettings
    @ObservationIgnored private var engine: (any SpeechEngine)?
    @ObservationIgnored private var engineResidency: ModelResidency?
    @ObservationIgnored private let detector: (any SpeechDetector)?
    @ObservationIgnored private let detectorResidency: ModelResidency?
    @ObservationIgnored private var current: Work?
    /// How the failing recognition failed, for the HUD.
    @ObservationIgnored private var failure: DictationFailure?
    @ObservationIgnored private var holdWatch: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: AsyncStream<DictationHUDState>.Continuation] = [:]
    @ObservationIgnored private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "voice")

    /// One session's audio and the work on it.
    private final class Work {
        let session: DictationMachine.Session
        let audio: DictationAudio
        var subscription: AudioSubscription?
        var target: Task<(any Sendable)?, Never>?
        var model: Task<Void, any Error>?
        var modelReady = false
        var stopping: Task<Void, Never>?
        var ticker: Task<Void, Never>?
        var silence: Task<Void, Never>?

        init(session: DictationMachine.Session, audio: DictationAudio) {
            self.session = session
            self.audio = audio
        }

        func stopTimers() {
            ticker?.cancel()
            silence?.cancel()
        }
    }

    public init(settings: VoiceSettings, microphone: any DictationMicrophone, paster: any DictationPaster,
                secureInput: (any DictationSecureInputRules)?, detector: (any SpeechDetector)?,
                makeEngine: @escaping (String) -> (any SpeechEngine)?, hooks: Hooks = Hooks(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) })
    {
        self.settings = settings
        self.microphone = microphone
        self.paster = paster
        self.secureInput = secureInput
        self.detector = detector
        self.makeEngine = makeEngine
        self.hooks = hooks
        self.sleep = sleep
        detectorResidency = detector.map { ModelResidency($0, unloadDelay: Self.unloadDelay(settings)) }
        setEngine(for: settings)
        secureInput?.onStop = { [weak self] in self?.handle(.secureInputChanged(true)) }
        secureInput?.onEscape = { [weak self] in self?.handle(.voice(.cancel)) }
    }

    /// The app's controller: the microphone, the store's models, and the
    /// system events that stop or cancel a recording.
    public convenience init(settings: VoiceSettings, capture: AudioCapture, store: VoiceModelStore,
                            paster: any DictationPaster, secureInput: (any DictationSecureInputRules)?,
                            hooks: Hooks)
    {
        self.init(settings: settings, microphone: capture, paster: paster, secureInput: secureInput,
                  detector: SileroVAD(store: store), makeEngine: { VoiceEngines.make(model: $0, store: store) },
                  hooks: hooks)
        observeSystem()
    }

    // MARK: - Inputs

    /// The voice hotkey, from `EngineMessage.voice`.
    public func voice(_ signal: VoiceSignal) {
        if machine.state == .idle, signal == .toggle || signal == .holdBegan {
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

    /// New settings from voice.json. A new model unloads the old one.
    public func apply(_ settings: VoiceSettings) {
        let old = self.settings
        self.settings = settings
        if settings.model != old.model {
            setEngine(for: settings)
        } else if settings.unloadAfterMinutes != old.unloadAfterMinutes {
            let delay = Self.unloadDelay(settings)
            Task { [engineResidency, detectorResidency] in
                await engineResidency?.setUnloadDelay(delay)
                await detectorResidency?.setUnloadDelay(delay)
            }
        }
    }

    /// Loads a model in the background after its download, so that the
    /// first dictation does not wait for CoreML. The dictation model stays
    /// for the idle time; another one is unloaded at once.
    public func warmUp(model id: String) async throws {
        if id == settings.model, let engineResidency {
            try await engineResidency.warmUp()
        } else if let engine = makeEngine(id) {
            defer { Task { await engine.unload() } }
            try await engine.prepare()
        }
    }

    /// Unloads the models now, e.g. when dictation is turned off.
    public func unloadModels() async {
        await engineResidency?.unload()
        await detectorResidency?.unload()
    }

    /// The HUD state now and after every change.
    public func hudUpdates() -> AsyncStream<DictationHUDState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: DictationHUDState.self, bufferingPolicy: .bufferingNewest(1))
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
            lastText = text
            lastTextPasted = false
            hud = .notPasted(.noAccessibility)
        case let .sessionActive(on):
            hooks.sessionChanged(on)
            if on {
                secureInput?.sessionBegan()
            } else {
                secureInput?.sessionEnded()
                current?.stopTimers()
                current = nil
            }
        case let .watchHold(on):
            watchHold(on)
        case let .sound(sound):
            if settings.sounds { hooks.play(sound) }
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
            hud = .failed(failure ?? .recognition(message))
            failure = nil
        }
    }

    private var recording: DictationHUDState.Recording {
        DictationHUDState.Recording(seconds: current?.audio.seconds ?? 0, level: min(1, (current?.audio.level ?? 0) * 4),
                                    preparingModel: current?.modelReady == false)
    }

    // MARK: - Session work

    private func start(_ session: DictationMachine.Session) {
        let audio = DictationAudio(
            onLimit: { [weak self] in
                Task { @MainActor in self?.handle(.captureEnded(session, .limit)) }
            },
            onInterruption: { [weak self] _ in
                // A new device, a lost one, a stall: what was said so far is recognized.
                Task { @MainActor in self?.handle(.captureEnded(session, .deviceChanged)) }
            })
        let work = Work(session: session, audio: audio)
        current?.stopTimers()
        current = work
        let paster = self.paster
        work.target = Task { await paster.captureTarget() }
        if let engineResidency {
            work.model = Task { [weak self, weak work] in
                try await engineResidency.load()
                work?.modelReady = true
                self?.refreshHUD()
            }
        } else {
            work.model = Task { throw VoiceModelFailure.unknownModel(self.settings.model) }
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
        let model = work.model
        let engineResidency = self.engineResidency
        // The model loaded for nothing still counts as used: the timer starts.
        Task {
            _ = try? await model?.value
            await engineResidency?.used()
        }
    }

    private func recognize(_ session: DictationMachine.Session, _: DictationMachine.Delivery) {
        guard let work = current, work.session == session else { return }
        let engine = self.engine
        let detector = self.detector
        let engineResidency = self.engineResidency
        let detectorResidency = self.detectorResidency
        Task(priority: .userInitiated) {
            await work.stopping?.value
            let audio = AudioBuffer16k(work.audio.samples)
            do {
                guard let engine, let model = work.model else {
                    throw VoiceModelFailure.unknownModel(settings.model)
                }
                try await model.value
                var loadedDetector: (any SpeechDetector)?
                if let detector, let detectorResidency {
                    do {
                        try await detectorResidency.load()
                        loadedDetector = detector
                    } catch {
                        log.error("speech detector: \(String(describing: error), privacy: .public)")
                    }
                }
                let outcome = try await DictationRecognition.recognize(audio, engine: engine, detector: loadedDetector)
                await engineResidency?.used()
                await detectorResidency?.used()
                handle(.recognized(session, outcome))
            } catch {
                await engineResidency?.used()
                log.error("dictation: \(String(describing: error), privacy: .public)")
                let message = String(describing: error)
                if !work.modelReady { failure = .model(message) }
                handle(.recognitionFailed(session, message))
            }
        }
    }

    private func paste(_ session: DictationMachine.Session, _ text: String) {
        lastText = text
        lastTextPasted = false
        let target = current?.session == session ? current?.target : nil
        let paster = self.paster
        Task {
            let result = await paster.paste(text, into: await target?.value)
            switch result {
            case .pasted:
                lastTextPasted = true
                hud = .pasted
                if settings.switchesLayout { hooks.pasted(text) }
            case .targetChanged:
                hud = .notPasted(.targetChanged)
            case .secureField:
                hud = .notPasted(.secureField)
            case let .failed(message):
                hud = .notPasted(.failed(message))
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
        guard settings.silenceStopSeconds > 0, let detector, let detectorResidency else { return }
        var watch = SilenceWatch(limit: Double(settings.silenceStopSeconds))
        let session = work.session
        let audio = work.audio
        work.silence = Task { [weak self] in
            guard (try? await detectorResidency.load()) != nil else { return }
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
                        self?.handle(.captureEnded(session, .silence))
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

    private func setEngine(for settings: VoiceSettings) {
        if let old = engineResidency {
            Task { await old.unload() }
        }
        engine = makeEngine(settings.model)
        engineResidency = engine.map { ModelResidency($0, unloadDelay: Self.unloadDelay(settings)) }
    }

    private static func unloadDelay(_ settings: VoiceSettings) -> Duration? {
        settings.unloadAfterMinutes > 0 ? .seconds(settings.unloadAfterMinutes * 60) : nil
    }

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
