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

    func end(_: AudioSubscription) async {
        lock.withLockUnchecked {
            audio = nil
            log.append("end")
        }
    }

    var isWaiting: Bool { lock.withLockUnchecked { gate != nil } }

    private var _selected: [String?] = []
    var selected: [String?] { lock.withLockUnchecked { _selected } }

    func select(_ uid: String?) async {
        lock.withLockUnchecked { _selected.append(uid) }
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

    func unload() async {
        unloads += 1
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
    func prepare() async throws {}
    func unload() async {}

    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        stride(from: 0, to: samples.count, by: VoiceActivity.chunk).map { start in
            samples[start..<min(samples.count, start + VoiceActivity.chunk)].contains { abs($0) > 0.1 } ? 0.9 : 0.05
        }
    }
}

@MainActor
private final class FakePaster: DictationPaster {
    var result: DictationPasteResult = .pasted
    private(set) var pasted: [String] = []
    private(set) var targets = 0

    func captureTarget() async -> (any Sendable)? {
        targets += 1
        return "front"
    }

    func paste(_ text: String, into target: (any Sendable)?) async -> DictationPasteResult {
        #expect(target as? String == "front")
        pasted.append(text)
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
    let paster = FakePaster()
    let secureInput = FakeSecureInput()
    var keysDown = true
    var sessionChanges: [Bool] = []
    var sounds: [DictationMachine.Sound] = []
    var holdLosses = 0
    var layoutTexts: [String] = []
    var controller: VoiceController!

    init(preferences: DictationPreferences = DictationPreferences(modelID: "fake", silenceStop: nil)) {
        let engine = self.engine
        controller = VoiceController(
            preferences: preferences, microphone: microphone, paster: paster, secureInput: secureInput,
            detector: FakeDetector(), makeEngine: { $0 == "fake" ? engine : nil },
            hooks: VoiceController.Hooks(
                sessionChanged: { [weak self] in self?.sessionChanges.append($0) },
                holdIsDown: { [weak self] in self?.keysDown ?? false },
                holdLost: { [weak self] in self?.holdLosses += 1 },
                pasted: { [weak self] in self?.layoutTexts.append($0) },
                play: { [weak self] in self?.sounds.append($0) }),
            sleep: { _ in try await Task.sleep(for: .milliseconds(2)) })
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
        #expect(rig.controller.lastText == "Привет, мир.")
        #expect(rig.controller.lastTextPasted)
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
        try? await Task.sleep(for: .milliseconds(50))
        // CoreML finished anyway; its text is dropped.
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.hud == .cancelled)
        #expect(rig.controller.lastText == nil)
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
        try? await Task.sleep(for: .milliseconds(50))
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
        #expect(rig.controller.lastText == "Привет, мир.")
        #expect(!rig.controller.lastTextPasted)
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
        #expect(rig.controller.lastText == "Привет, мир.")
        #expect(rig.state == .idle)
    }

    @Test func timeoutOffersOnlyCopy() async {
        let rig = Rig()
        rig.paster.result = .timedOut
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.timedOut) })
        #expect(!NotPastedReason.timedOut.offersPaste)
        #expect(rig.controller.lastText == "Привет, мир.")
        #expect(rig.layoutTexts.isEmpty)
    }

    @Test func secureInputOfAnotherApp() async {
        let rig = Rig()
        rig.paster.result = .secureInput(owner: "Terminal")
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureInput(owner: "Terminal")) })
        #expect(NotPastedReason.secureInput(owner: "Terminal").offersPaste)
        #expect(!rig.controller.lastTextIsPrivate)
    }

    @Test func passwordFieldKeepsTheTextPrivate() async {
        let rig = Rig()
        rig.paster.result = .secureField
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(rig.controller.lastTextIsPrivate)
        #expect(!NotPastedReason.secureField.offersPaste)
    }

    @Test func aNewMicrophoneWaitsForTheSessionToEnd() async {
        let rig = Rig()
        #expect(await rig.until { rig.microphone.selected == [nil] })
        await rig.startRecording()
        rig.controller.apply(DictationPreferences(microphoneUID: "usb", modelID: "fake", silenceStop: nil))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.microphone.selected == [nil])
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.microphone.selected == [nil, "usb"] })
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
        try? await Task.sleep(for: .milliseconds(50))
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
        #expect(rig.controller.lastText == "Привет, мир.")
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
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.holdLosses == 0)
        rig.keysDown = false
        #expect(await rig.until { rig.holdLosses == 1 })
        // The tap answers with the hold's end.
        rig.controller.voice(.holdEnded(reason: .lost))
        #expect(await rig.until { rig.state == .idle })
        try? await Task.sleep(for: .milliseconds(20))
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
}
