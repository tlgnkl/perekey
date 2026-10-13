// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// A microphone without hardware. `begin` waits while `hold` is set; `push`
/// feeds the dictation's audio.
private final class FakeMicrophone: DictationMicrophone, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: ())
    private var audio: DictationAudio?
    private var gate: CheckedContinuation<Void, Never>?
    private var nextID: UInt64 = 0
    var hold = false
    var fails: AudioCaptureError?
    private(set) var log: [String] = []

    func begin(_ audio: DictationAudio) async throws -> AudioSubscription {
        if lock.withLockUnchecked({ hold }) {
            await withCheckedContinuation { continuation in lock.withLockUnchecked { gate = continuation } }
        }
        return try lock.withLockUnchecked {
            if let fails { throw fails }
            self.audio = audio
            nextID += 1
            log.append("begin")
            return AudioSubscription(id: nextID)
        }
    }

    private(set) var accessRequests = 0

    func requestAccess() async {
        lock.withLockUnchecked { accessRequests += 1 }
    }

    func end(_: AudioSubscription) async {
        lock.withLockUnchecked {
            audio = nil
            log.append("end")
        }
    }

    var isWaiting: Bool { lock.withLockUnchecked { gate != nil } }

    private var _selected: [String?] = []
    var selected: [String?] { lock.withLockUnchecked { _selected } }

    /// A microphone was chosen while one was on.
    private(set) var selectedWhileOn = false

    func select(_ uid: String?) async {
        lock.withLockUnchecked {
            _selected.append(uid)
            if audio != nil { selectedWhileOn = true }
        }
    }

    func release() {
        let gate = lock.withLockUnchecked {
            hold = false
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    var isOn: Bool { lock.withLockUnchecked { audio != nil } }

    /// Speech: loud samples, as the fake detector hears them.
    func speak(seconds: Double = 1, level: Float = 0.5) {
        let audio = lock.withLockUnchecked { self.audio }
        let samples = [Float](repeating: level, count: Int(seconds * VoiceCore.sampleRate))
        samples.withUnsafeBufferPointer { audio?.receive($0, hostTime: 1) }
    }

    func interrupt(_ reason: AudioCaptureInterruption) {
        lock.withLockUnchecked { self.audio }?.captureInterrupted(reason)
    }
}

/// A recognizer that answers when the test lets it.
private actor FakeEngine: SpeechEngine {
    nonisolated let id: String
    private var text: String
    private var gate: CheckedContinuation<Void, Never>?
    private var holds = false
    private(set) var prepares = 0
    private(set) var unloads = 0
    private(set) var heard: [Int] = []
    private var prepared = false

    init(id: String = "fake", text: String = "Привет, мир.") {
        self.id = id
        self.text = text
    }

    func set(text: String) { self.text = text }
    func holdTranscription() { holds = true }

    func finish() {
        holds = false
        gate?.resume()
        gate = nil
    }

    var isTranscribing: Bool { gate != nil }

    func prepare() async throws {
        prepares += 1
        prepared = true
    }

    /// The model went while a transcription ran.
    private(set) var unloadedWhileTranscribing = false

    func unload() async {
        unloads += 1
        if gate != nil { unloadedWhileTranscribing = true }
        prepared = false
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        guard prepared else { throw SpeechEngineError.notPrepared }
        heard.append(audio.samples.count)
        if holds { await withCheckedContinuation { gate = $0 } }
        return Transcript(text: text)
    }
}

private actor FakeDetector: SpeechDetector {
    private(set) var calls = 0

    func prepare() async throws {}
    func unload() async {}

    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        calls += 1
        return stride(from: 0, to: samples.count, by: VoiceActivity.chunk).map { start in
            samples[start..<min(samples.count, start + VoiceActivity.chunk)].contains { abs($0) > 0.1 } ? 0.9 : 0.05
        }
    }
}

@MainActor
private final class FakePaster: DictationPaster {
    var result: DictationPasteResult = .pasted
    var hasTarget = true
    /// Called as the paste begins.
    var pasting: (() -> Void)?
    /// Awaited before the paste answers.
    var waits: (() async -> Void)?
    private(set) var pasted: [String] = []
    private(set) var finished = 0
    private(set) var targets = 0

    func captureTarget() async -> (any Sendable)? {
        targets += 1
        return "front"
    }

    func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult {
        #expect(target as? String == "front")
        pasting?()
        pasted.append(text)
        await waits?()
        finished += 1
        return result
    }
}

@MainActor
private final class FakeSecureInput: DictationSecureInputRules {
    var allowsStart = true
    var onStop: (@MainActor () -> Void)?
    var onEscape: (@MainActor () -> Void)?
    private(set) var sessions: [Bool] = []

    func sessionBegan() { sessions.append(true) }
    func sessionEnded() { sessions.append(false) }
}

/// The controller with fakes around it, and what its hooks were asked.
@MainActor
private final class Rig {
    let microphone = FakeMicrophone()
    let engine = FakeEngine()
    let otherEngine = FakeEngine(id: "fake2", text: "Другая модель.")
    let detector = FakeDetector()
    let paster = FakePaster()
    let secureInput = FakeSecureInput()
    var keysDown = true
    var sessionChanges: [Bool] = []
    var sounds: [DictationMachine.Sound] = []
    var holdLosses = 0
    var holdPolls = 0
    /// Sleeps of the controller's timers so far: they show time passing.
    let sleeps = OSAllocatedUnfairLock(initialState: 0)
    var layoutTexts: [String] = []
    var controller: VoiceController!

    init(preferences: DictationPreferences = DictationPreferences(modelID: "fake", silenceStop: nil),
         limitSeconds: Int = DictationAudio.limitSeconds)
    {
        let engines = ["fake": engine, "fake2": otherEngine]
        controller = VoiceController(
            preferences: preferences, microphone: microphone, paster: paster, secureInput: secureInput,
            detector: detector, makeEngine: { engines[$0] },
            hooks: VoiceController.Hooks(
                sessionChanged: { [weak self] in self?.sessionChanges.append($0) },
                holdIsDown: { [weak self] in
                    self?.holdPolls += 1
                    return self?.keysDown ?? false
                },
                holdLost: { [weak self] in self?.holdLosses += 1 },
                pasted: { [weak self] in self?.layoutTexts.append($0) },
                play: { [weak self] in self?.sounds.append($0) }),
            limitSeconds: limitSeconds,
            sleep: { [sleeps] _ in
                sleeps.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(2))
            })
    }

    var state: DictationMachine.State { controller.state }
    var hud: DictationHUDState { controller.hud }

    func until(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return await condition()
    }

    /// Tap, the microphone is on, some speech.
    func startRecording() async {
        controller.voice(.toggle)
        #expect(await until { if case .recording = self.state { true } else { false } })
        microphone.speak()
    }
}

@MainActor
struct VoiceControllerTests {
    @Test func dictationEndToEnd() async {
        let rig = Rig()
        await rig.startRecording()
        #expect(rig.sessionChanges == [true])
        #expect(rig.sounds == [.start])
        #expect(rig.secureInput.sessions == [true])
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(rig.controller.last == DictatedText(text: "Привет, мир.", pasted: true, isPrivate: false))
        #expect(rig.layoutTexts == ["Привет, мир."])
        #expect(rig.sounds == [.start, .stop])
        #expect(rig.sessionChanges == [true, false])
        #expect(rig.secureInput.sessions == [true, false])
        #expect(rig.microphone.log == ["begin", "end"])
        #expect(rig.state == .idle)
        #expect(await rig.engine.heard == [16000])
    }

    @Test func stopWhileStarting() async {
        let rig = Rig()
        rig.microphone.hold = true
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.microphone.isWaiting })
        rig.controller.voice(.toggle)
        #expect(rig.state == .starting(1, .tap, pending: .stop(.trigger)))
        rig.microphone.release()
        // Started and stopped at once: nothing was said, nothing is pasted.
        #expect(await rig.until { rig.hud == .nothingHeard })
        #expect(rig.microphone.log == ["begin", "end"])
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.state == .idle)
    }

    @Test func escWhileStarting() async {
        let rig = Rig()
        rig.microphone.hold = true
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.microphone.isWaiting })
        rig.controller.voice(.cancel)
        rig.microphone.release()
        #expect(await rig.until { rig.hud == .cancelled })
        #expect(await rig.until { !rig.microphone.isOn })
        #expect(rig.state == .idle)
    }

    @Test func escWhileRecognizing() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        #expect(rig.hud == .recognizing(preparingModel: false))
        rig.controller.voice(.cancel)
        #expect(rig.hud == .cancelled)
        #expect(rig.state == .idle)
        await rig.engine.finish()
        #expect(await rig.until { rig.controller.recognitionsDone == 1 })
        // CoreML finished anyway; its text is dropped.
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.hud == .cancelled)
        #expect(rig.controller.last == nil)
    }

    @Test func anOldSessionsResultIsDropped() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        rig.controller.voice(.cancel)
        // A new session while the old recognition still runs.
        await rig.startRecording()
        await rig.engine.set(text: "Второй раз.")
        await rig.engine.finish()
        #expect(await rig.until { rig.controller.recognitionsDone == 1 })
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.state == .recording(2, .tap))
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Второй раз."])
    }

    @Test func tapWhileRecognizing() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        rig.controller.voice(.toggle)
        #expect(rig.hud == .stillRecognizing)
        await rig.engine.finish()
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.microphone.log == ["begin", "end"])
    }

    @Test func deviceChangeRecognizesWhatWasSaid() async {
        let rig = Rig()
        await rig.startRecording()
        rig.microphone.interrupt(.deviceLost)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(await rig.engine.heard == [16000])
    }

    @Test func secureInputInTheMiddle() async {
        let rig = Rig()
        await rig.startRecording()
        rig.paster.result = .secureField
        rig.secureInput.onStop?()
        // Recognized; the paste found the password field and kept out.
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(rig.controller.last == DictatedText(text: "Привет, мир.", pasted: false, isPrivate: true))
        #expect(rig.layoutTexts.isEmpty)
    }

    @Test func secureInputKeepsDictationSilent() async {
        let rig = Rig()
        rig.secureInput.allowsStart = false
        rig.controller.voice(.toggle)
        #expect(rig.state == .idle)
        #expect(rig.hud == .hidden)
        #expect(rig.sounds.isEmpty)
        rig.secureInput.allowsStart = true
        await rig.startRecording()
    }

    @Test func secureInputEscape() async {
        let rig = Rig()
        await rig.startRecording()
        rig.secureInput.onEscape?()
        #expect(rig.hud == .cancelled)
        #expect(await rig.until { !rig.microphone.isOn })
    }

    @Test func targetChanged() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.targetChanged) })
        #expect(rig.controller.last?.text == "Привет, мир.")
        #expect(rig.state == .idle)
    }

    @Test func timeoutOffersOnlyCopy() async {
        let rig = Rig()
        rig.paster.result = .timedOut
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.timedOut) })
        #expect(!NotPastedReason.timedOut.offersPaste)
        #expect(rig.controller.last?.text == "Привет, мир.")
        #expect(rig.layoutTexts.isEmpty)
    }

    @Test func secureInputOfAnotherApp() async {
        let rig = Rig()
        rig.paster.result = .secureInput(owner: "Terminal")
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureInput(owner: "Terminal")) })
        #expect(NotPastedReason.secureInput(owner: "Terminal").offersPaste)
        #expect(rig.controller.last?.isPrivate == true, "Secure Input of another app: not for the history")
    }

    @Test func passwordFieldKeepsTheTextPrivate() async {
        let rig = Rig()
        rig.paster.result = .secureField
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(rig.controller.last?.isPrivate == true)
        #expect(!NotPastedReason.secureField.offersPaste)
    }

    @Test func aNewMicrophoneWaitsForTheSessionToEnd() async {
        let rig = Rig()
        #expect(await rig.until { rig.microphone.selected == [nil] })
        await rig.startRecording()
        rig.controller.apply(DictationPreferences(microphoneUID: "usb", modelID: "fake", silenceStop: nil))
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.microphone.selected == [nil, "usb"] })
        #expect(!rig.microphone.selectedWhileOn)
        rig.controller.apply(DictationPreferences(modelID: "fake", silenceStop: nil))
        #expect(await rig.until { rig.microphone.selected == [nil, "usb", nil] })
    }

    @Test func silenceIsNotPasted() async {
        let rig = Rig()
        rig.controller.voice(.toggle)
        #expect(await rig.until { if case .recording = rig.state { true } else { false } })
        rig.microphone.speak(seconds: 2, level: 0.001)
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .nothingHeard })
        #expect(await rig.engine.heard.isEmpty)
        #expect(rig.paster.pasted.isEmpty)
    }

    @Test func silenceStopsTheRecording() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "fake", silenceStop: .seconds(1)))
        await rig.startRecording()
        // A second of speech, checked; then two of quiet.
        #expect(await rig.until { await rig.detector.calls >= 1 })
        rig.microphone.speak(seconds: 2, level: 0.001)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.sounds == [.start, .stop])
    }

    @Test func accessibilityLostKeepsTheText() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.accessibilityLost()
        #expect(await rig.until { rig.hud == .notPasted(.noAccessibility) })
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.controller.last?.text == "Привет, мир.")
    }

    @Test func sleepCancels() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.system(.sleep)
        #expect(rig.hud == .cancelled)
        #expect(await rig.until { !rig.microphone.isOn })
        #expect(rig.paster.pasted.isEmpty)
    }

    @Test func lockedScreenRecognizes() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.system(.sessionLost)
        #expect(await rig.until { rig.hud == .pasted })
    }

    @Test func microphoneDenied() async {
        let rig = Rig()
        rig.microphone.fails = .notAuthorized
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.microphoneDenied) })
        #expect(rig.sessionChanges == [true, false])
        #expect(rig.state == .idle)
    }

    @Test func noModel() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "missing", silenceStop: nil))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until {
            if case .failed(.model) = rig.hud { true } else { false }
        })
        #expect(rig.paster.pasted.isEmpty)
    }

    @Test func holdEndsWhenItsKeysAreFoundUp() async {
        let rig = Rig()
        rig.controller.voice(.holdBegan)
        #expect(await rig.until { if case .recording = rig.state { true } else { false } })
        #expect(await rig.until { rig.holdPolls >= 2 })
        #expect(rig.holdLosses == 0)
        rig.keysDown = false
        #expect(await rig.until { rig.holdLosses == 1 })
        // The tap answers with the hold's end.
        rig.controller.voice(.holdEnded(reason: .lost))
        #expect(await rig.until { rig.state == .idle })
        #expect(!rig.controller.isWatchingHold)
        #expect(rig.holdLosses == 1)
    }

    @Test func soundsCanBeOff() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "fake", playsSounds: false, silenceStop: nil))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.sounds.isEmpty)
    }

    @Test func layoutSwitchCanBeOff() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "fake", switchesLayout: false, silenceStop: nil))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.layoutTexts.isEmpty)
    }

    @Test func hudStream() async {
        let rig = Rig()
        let stream = rig.controller.hudUpdates()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .hidden)
        rig.controller.voice(.toggle)
        #expect(await iterator.next() == .starting)
    }

    @Test func modelIsLoadedOnceAndKept() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.paster.pasted.count == 2 })
        #expect(await rig.engine.prepares == 1)
        #expect(await rig.engine.unloads == 0)
        await rig.controller.unloadModels()
        #expect(await rig.engine.unloads == 1)
    }
    // MARK: - Review fixes

    @Test func shutdownDuringARecording() async {
        let rig = Rig()
        let stream = rig.controller.hudUpdates()
        await rig.startRecording()
        await rig.controller.shutdown()
        #expect(!rig.microphone.isOn)
        #expect(rig.sessionChanges == [true, false], "the tap gives Esc back")
        #expect(rig.secureInput.sessions == [true, false])
        #expect(rig.state == .idle)
        #expect(rig.hud == .hidden)
        var states: [DictationHUDState] = []
        for await state in stream { states.append(state) }
        #expect(states.last == .hidden, "the stream ended")
        #expect(await rig.engine.unloads == 1)
        // Nothing starts again.
        rig.controller.voice(.toggle)
        #expect(rig.state == .idle)
        #expect(rig.microphone.log == ["begin", "end"])
        #expect(rig.secureInput.onStop == nil)
    }

    @Test func shutdownWaitsForARecognitionInProgress() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        let shutdown = Task { await rig.controller.shutdown() }
        #expect(await rig.until { rig.state == .idle })
        #expect(await rig.engine.unloads == 0, "the model stays under a running transcription")
        await rig.engine.finish()
        await shutdown.value
        #expect(await rig.engine.unloads == 1)
        #expect(await !rig.engine.unloadedWhileTranscribing)
        #expect(rig.paster.pasted.isEmpty)
    }

    @Test func unloadModelsWaitsForATranscription() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        let unloading = Task { await rig.controller.unloadModels() }
        await rig.engine.finish()
        #expect(await rig.until { rig.hud == .pasted })
        await unloading.value
        #expect(await rig.engine.unloads == 1)
        #expect(await !rig.engine.unloadedWhileTranscribing)
    }

    @Test func aNewModelWaitsForTheSessionOnTheOldOne() async {
        let rig = Rig()
        await rig.engine.holdTranscription()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.engine.isTranscribing })
        rig.controller.apply(DictationPreferences(modelID: "fake2", silenceStop: nil))
        await rig.engine.finish()
        // The session keeps the model it started with.
        #expect(await rig.until { rig.paster.pasted == ["Привет, мир."] })
        #expect(await rig.until { await rig.engine.unloads == 1 })
        #expect(await !rig.engine.unloadedWhileTranscribing)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.paster.pasted.count == 2 })
        #expect(rig.paster.pasted.last == "Другая модель.")
    }

    @Test func warmUpSharesTheDictationCopy() async throws {
        let rig = Rig()
        try await rig.controller.warmUp(model: "fake")
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.engine.prepares == 1)
    }

    @Test func theLimitStopsAndRecognizes() async {
        let rig = Rig(limitSeconds: 1)
        await rig.startRecording()
        rig.microphone.speak(seconds: 1)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.engine.heard == [16000])
    }

    @Test func escEndsTheHoldWatch() async {
        let rig = Rig()
        rig.controller.voice(.holdBegan)
        #expect(await rig.until { if case .recording = rig.state { true } else { false } })
        #expect(rig.controller.isWatchingHold)
        rig.controller.voice(.cancel)
        #expect(!rig.controller.isWatchingHold)
        rig.keysDown = false
        // A tap session runs its timers: a hold watch left behind would poll meanwhile.
        await rig.startRecording()
        let sleeps = rig.sleeps.withLock { $0 }
        #expect(await rig.until { rig.sleeps.withLock { $0 } >= sleeps + 20 })
        #expect(rig.holdLosses == 0)
    }

    @Test func escGoesBackToTheAppForThePaste() async {
        let rig = Rig()
        var takenDuringPaste: Bool?
        rig.paster.pasting = { [unowned rig] in takenDuringPaste = rig.sessionChanges.last }
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(takenDuringPaste == false)
        #expect(rig.sessionChanges == [true, false])
        #expect(rig.secureInput.sessions == [true, false])
    }

    @Test func noAppInFrontNoRecording() async {
        let rig = Rig()
        rig.paster.hasTarget = false
        rig.controller.voice(.toggle)
        #expect(rig.state == .idle)
        #expect(rig.hud == .hidden)
        #expect(rig.microphone.log.isEmpty)
    }

    @Test func shutdownWhileTheMicrophoneStarts() async {
        let rig = Rig()
        rig.microphone.hold = true
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.microphone.isWaiting })
        await rig.controller.shutdown()
        #expect(rig.state == .idle)
        #expect(rig.sessionChanges == [true, false])
        #expect(rig.secureInput.sessions == [true, false])
        rig.microphone.release()
        // The start that comes late is stopped at once.
        #expect(await rig.until { rig.microphone.log == ["begin", "end"] })
        #expect(!rig.microphone.isOn)
        #expect(rig.hud == .hidden)
    }

    @Test func shutdownDuringThePaste() async {
        let rig = Rig()
        var gate: CheckedContinuation<Void, Never>?
        rig.paster.waits = { await withCheckedContinuation { gate = $0 } }
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { gate != nil })
        await rig.controller.shutdown()
        gate?.resume()
        #expect(await rig.until { rig.paster.pasted.count == 1 })
        #expect(await rig.until { rig.paster.finished == 1 })
        #expect(rig.hud == .hidden, "no HUD after dictation went off")
        #expect(rig.layoutTexts.isEmpty, "no layout switch either")
    }

    @Test func theMicrophoneIsAskedForBeforeItStarts() async {
        let rig = Rig()
        await rig.startRecording()
        #expect(rig.microphone.accessRequests == 1)
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
    }

    @Test func theHUDPastesTheLastTextAgain() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.targetChanged) })
        rig.paster.result = .pasted
        rig.controller.pasteLast()
        #expect(rig.hud == .pasting)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир.", "Привет, мир."])
        #expect(rig.controller.last == DictatedText(text: "Привет, мир.", pasted: true, isPrivate: false))
        #expect(rig.layoutTexts == ["Привет, мир."])
    }

    @Test func pastingAgainIntoAPasswordFieldStaysOut() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.targetChanged) })
        rig.paster.result = .secureField
        rig.controller.pasteLast()
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(rig.controller.last?.isPrivate == true)
    }

    @Test func pasteLastAnswersOnlyAfterATextThatWasNotPasted() async {
        let rig = Rig()
        // Nothing yet.
        rig.controller.pasteLast()
        #expect(rig.hud == .hidden)
        // A timeout: the first paste may still land, so no second one.
        rig.paster.result = .timedOut
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.timedOut) })
        rig.controller.pasteLast()
        #expect(rig.hud == .notPasted(.timedOut))
        #expect(rig.paster.pasted.count == 1)
        // A text that went in is not pasted twice.
        let done = Rig()
        await done.startRecording()
        done.controller.voice(.toggle)
        #expect(await done.until { done.hud == .pasted })
        done.controller.pasteLast()
        #expect(done.hud == .pasted && done.paster.pasted.count == 1)
    }
}
