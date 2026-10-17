// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import PerekeyCore
import PerekeyInput
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

    /// The prompt of each transcription.
    private(set) var prompts: [String?] = []

    func transcribe(_ audio: AudioBuffer16k, prompt: String?) async throws -> Transcript {
        prompts.append(prompt)
        return try await transcribe(audio)
    }

    func transcribe(_ audio: AudioBuffer16k) async throws -> Transcript {
        guard prepared else { throw SpeechEngineError.notPrepared }
        heard.append(audio.samples.count)
        if holds { await withCheckedContinuation { gate = $0 } }
        return Transcript(text: text)
    }
}

/// A cloud speech model that fails, answers or hangs as the test says.
private actor FakeCloudEngine: SpeechEngine {
    enum Behavior { case fail, answer(String), hang }

    nonisolated let id = "cloud:groq:whisper"
    private var behavior: Behavior = .fail
    private(set) var calls = 0
    private(set) var cancelled = 0
    private(set) var prompts: [String?] = []

    func set(_ behavior: Behavior) { self.behavior = behavior }

    func transcribe(_ audio: AudioBuffer16k, prompt: String?) async throws -> Transcript {
        prompts.append(prompt)
        return try await transcribe(audio)
    }
    func prepare() async throws {}
    func unload() async {}

    func transcribe(_: AudioBuffer16k) async throws -> Transcript {
        calls += 1
        switch behavior {
        case .fail:
            throw OpenAICompatibleClient.Failure.server(status: 503, message: nil)
        case let .answer(text):
            return Transcript(text: text)
        case .hang:
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled += 1
                throw error
            }
            return Transcript(text: "")
        }
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
    private(set) var copied: [String] = []
    private(set) var returns = 0

    func copy(_ text: String) { copied.append(text) }

    func pressReturn(in target: (any Sendable)?) async -> DictationPasteResult {
        #expect(target as? String == "front")
        returns += 1
        return .pasted
    }
    /// What the field has before the caret.
    var context: String?
    private(set) var contextAsked = 0
    var application: DictationApplication?

    /// Awaited before the caret context answers.
    var contextWaits: (() async -> Void)?

    func caretContext(into _: (any Sendable)?) async -> String? {
        contextAsked += 1
        await contextWaits?()
        return context
    }

    func application(of _: (any Sendable)?) -> DictationApplication? { application }

    /// What the field `captureTarget` returns is, whatever the paste answers.
    var targetPrivacy: DictationPrivacy = .normal
    func privacy(of _: (any Sendable)?) -> DictationPrivacy { targetPrivacy }

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
    let cloud = FakeCloudEngine()
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
    /// The text rules of the test, and what they were asked.
    var editor: (String, String?) -> String = { text, _ in text }
    var edits: [(text: String, before: String?)] = []
    /// The mode's filler words rule of each edit.
    var fillerRules: [Bool?] = []
    var prompt: String?
    var dictionary: (String) -> String = { $0 }
    var records: [DictationRecord] = []

    init(preferences: DictationPreferences = DictationPreferences(modelID: "fake", silenceStop: nil),
         limitSeconds: Int = DictationAudio.limitSeconds)
    {
        let engines: [String: any SpeechEngine] = ["fake": engine, "fake2": otherEngine, cloud.id: cloud]
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
                play: { [weak self] in self?.sounds.append($0) },
                edit: { [weak self] text, before, removesFillers in
                    self?.edits.append((text, before))
                    self?.fillerRules.append(removesFillers)
                    return self?.editor(text, before) ?? text
                },
                dictionary: { [weak self] in self?.dictionary($0) ?? $0 },
                prompt: { [weak self] in self?.prompt },
                record: { [weak self] in self?.records.append($0) }),
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
    @Test func textRulesRunOnTheRecognizedTextWithTheCaretContext() async {
        let rig = Rig()
        rig.paster.context = "Я сказал, что "
        rig.editor = { text, before in before == nil ? text : text.lowercased() }
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.edits.map(\.text) == ["Привет, мир."])
        #expect(rig.edits.map(\.before) == ["Я сказал, что "])
        #expect(rig.paster.pasted == ["привет, мир."])
        #expect(rig.controller.last?.text == "привет, мир.")
        #expect(rig.layoutTexts == ["привет, мир."])
    }

    @Test func unreadableFieldPassesNilContext() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.edits.map(\.before) == [nil])
    }

    @Test func textRulesLeavingNothingPasteNothing() async {
        let rig = Rig()
        rig.editor = { _, _ in "" }
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .nothingHeard })
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.records.isEmpty)
        #expect(await rig.until { rig.state == .idle })
    }

    @Test func whisperGetsThePromptFromTheDictionary() async {
        let rig = Rig()
        rig.prompt = "Perekey, Parakeet"
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.engine.prompts == ["Perekey, Parakeet"])
    }

    @Test func finishedDictationGoesToTheHistoryHook() async {
        let rig = Rig()
        rig.paster.application = DictationApplication(bundleID: "com.apple.Notes", name: "Notes")
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.until { rig.records.count == 1 })
        let record = rig.records[0]
        #expect(record.text == "Привет, мир.")
        #expect(record.bundleID == "com.apple.Notes" && record.appName == "Notes")
        #expect(record.model == "fake")
        #expect(record.pasted && record.privacy == .normal)
        #expect(record.duration > 0 && record.audio?.isEmpty == false)
    }

    /// The file queue learns when a session starts and once its text is in.
    @Test func dictationActivityFollowsTheSession() async {
        let rig = Rig()
        let activity = DictationActivity()
        rig.controller.dictation = activity
        await rig.startRecording()
        #expect(activity.isActive)
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.until { !activity.isActive })
        activity.began()
        await rig.controller.shutdown()
        #expect(!activity.isActive)
    }

    @Test func passwordFieldAndSecureInputAreMarkedPrivateAndNotRecorded() async {
        for result in [DictationPasteResult.secureField, .secureInput(owner: "Terminal")] {
            let rig = Rig()
            rig.paster.result = result
            await rig.startRecording()
            rig.controller.voice(.toggle)
            #expect(await rig.until { rig.controller.last != nil && rig.state == .idle })
            #expect(rig.controller.last?.isPrivate == true)
            #expect(rig.records.isEmpty)
        }
    }

    @Test func aPasswordTargetStaysPrivateWhateverTheRefusal() async {
        let refusals: [DictationPasteResult] = [.targetChanged, .failed("modifiersHeld"), .failed("noAccess"), .timedOut, .pasted]
        for result in refusals {
            let rig = Rig()
            rig.paster.targetPrivacy = .secureField
            rig.paster.result = result
            await rig.startRecording()
            rig.controller.voice(.toggle)
            #expect(await rig.until { rig.state == .idle && rig.controller.last != nil })
            #expect(rig.controller.last?.isPrivate == true, "\(result)")
            #expect(rig.records.isEmpty, "\(result): nothing private goes to the history")
        }
    }

    @Test func secureInputNowKeepsATimedOutDictationOutOfTheHistory() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureInput
        rig.paster.result = .timedOut
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.controller.last != nil && rig.state == .idle })
        #expect(rig.controller.last?.isPrivate == true)
        #expect(rig.records.isEmpty)
    }

    @Test func keptTextOfAPasswordTargetIsPrivateAndUnrecorded() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureField
        await rig.startRecording()
        rig.controller.accessibilityLost()
        #expect(await rig.until { rig.hud == .notPasted(.noAccessibility) })
        #expect(rig.controller.last?.isPrivate == true)
        #expect(rig.records.isEmpty)
    }

    @Test func keptTextOfAnOrdinaryFieldIsRecorded() async {
        let rig = Rig()
        await rig.startRecording()
        rig.controller.accessibilityLost()
        #expect(await rig.until { rig.hud == .notPasted(.noAccessibility) })
        #expect(rig.controller.last?.isPrivate == false)
        #expect(await rig.until { rig.records.count == 1 })
        #expect(!rig.records[0].pasted)
    }

    @Test func keptTextOfATargetWithoutElementIsNotRecordedNorPrivate() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .unknown
        await rig.startRecording()
        rig.controller.accessibilityLost()
        #expect(await rig.until { rig.hud == .notPasted(.noAccessibility) })
        #expect(rig.controller.last?.isPrivate == false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.records.isEmpty)
    }

    @Test func targetWithoutElementIsNotStoredButStaysOnTheHUD() async {
        for result in [DictationPasteResult.targetChanged, .timedOut, .pasted] {
            let rig = Rig()
            rig.paster.targetPrivacy = .unknown
            rig.paster.result = result
            await rig.startRecording()
            rig.controller.voice(.toggle)
            #expect(await rig.until { rig.controller.last != nil })
            #expect(rig.controller.last?.isPrivate == false)
            #expect(rig.records.isEmpty)
        }
    }

    @Test func fieldWithElementIsStored() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .normal
        rig.paster.result = .timedOut
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.records.count == 1 })
    }

    @Test func pasteFromTheHUDAddsNoSecondEntry() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.records.count == 1 })
        rig.paster.result = .pasted
        rig.controller.pasteLast()
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.records.count == 1)
    }

    @Test func notPastedDictationStillGoesToTheHook() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.records.count == 1 })
        #expect(rig.records[0].privacy == .normal && !rig.records[0].pasted)
    }

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

    @Test func aStoppedTypingOffersOnlyCopyAndGoesToTheHistory() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .normal
        rig.paster.result = .interrupted
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.interrupted) })
        #expect(rig.controller.last?.pasted == false)
        #expect(rig.layoutTexts.isEmpty)
        #expect(await rig.until { rig.records.count == 1 })
        #expect(!rig.records[0].pasted)
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

    @Test func secureInputWhileTypingOffersOnlyCopyAndStaysOutOfTheHistory() async {
        // The start of the text is typed: "Вставить" would put it in twice.
        let rig = Rig()
        rig.paster.targetPrivacy = .normal
        rig.paster.result = .interruptedBySecureInput
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.interrupted) })
        #expect(!NotPastedReason.interrupted.offersPaste)
        #expect(rig.controller.last?.isPrivate == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.records.isEmpty)
    }

    @Test func aNewDictationCancelsPastingAgain() async {
        // Typing into a terminal takes a while: two typings must not mix.
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.targetChanged) })
        final class Seen { var cancelled = false }
        let seen = Seen()
        rig.paster.result = .interrupted
        rig.paster.waits = {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            seen.cancelled = true
        }
        rig.controller.pasteLast()
        #expect(rig.hud == .pasting)
        await rig.startRecording()
        #expect(await rig.until { seen.cancelled })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.hud != .notPasted(.interrupted), "the old paste does not take over the new dictation's HUD")
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

    @Test func onlyTheDictationModelWarmsUpAfterADownload() async {
        let rig = Rig()
        await rig.controller.modelDownloaded("fake2")
        #expect(await rig.otherEngine.prepares == 0, "a model downloaded to try stays unloaded")
        await rig.controller.modelDownloaded("fake")
        #expect(await rig.engine.prepares == 1)
    }

    @Test func aNewDictationKeepsItsHUDWhileThePasteAgainAnswers() async {
        let rig = Rig()
        rig.paster.result = .targetChanged
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.targetChanged) })
        var gate: CheckedContinuation<Void, Never>?
        rig.paster.waits = { await withCheckedContinuation { gate = $0 } }
        rig.controller.pasteLast()
        #expect(await rig.until { gate != nil })
        rig.paster.waits = nil
        rig.controller.voice(.toggle)
        #expect(await rig.until { if case .recording = rig.state { true } else { false } })
        gate?.resume()
        #expect(await rig.until { rig.paster.finished == 2 })
        if case .recording = rig.hud {} else { Issue.record("the new dictation's HUD was overwritten: \(rig.hud)") }
        #expect(rig.controller.last?.pasted == false)
    }
}

/// Modes for the controller: a fixed plan, and a language model that answers,
/// fails or hangs as the test says.
@MainActor
private final class FakeModes: DictationModeSource {
    var fixed: DictationPlan
    var answer: String? = "Привет, мир!"
    var hangs = false
    private(set) var asked: [String] = []
    private(set) var cancelled = 0
    private(set) var ended: [String] = []

    init(_ plan: DictationPlan) {
        fixed = plan
    }

    func plan() -> DictationPlan { fixed }

    func refine(_ text: String, plan: DictationPlan) async throws -> String {
        asked.append(text)
        if hangs {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled += 1
                throw error
            }
        }
        guard let answer else { throw OpenAICompatibleClient.Failure.server(status: 500, message: nil) }
        return answer
    }

    func sessionEnded(_ plan: DictationPlan) { ended.append(plan.modeID) }
}

private extension DictationPlan {
    static func refining(timeout: Duration = .seconds(5)) -> DictationPlan {
        DictationPlan(modeID: "clean", modeName: "Чистовик",
                      refine: Refine(endpointName: "Ollama", isCloud: false, timeout: timeout))
    }
}

@MainActor
struct VoiceControllerModeTests {
    @Test func theLanguageModelEditsTheText() async {
        let rig = Rig()
        let modes = FakeModes(.refining())
        rig.controller.modes = modes
        await rig.startRecording()
        if case let .recording(recording) = rig.hud { #expect(recording.mode == "Чистовик") }
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(modes.asked == ["Привет, мир."])
        #expect(rig.paster.pasted == ["Привет, мир!"])
        #expect(rig.controller.last?.text == "Привет, мир!")
        #expect(modes.ended == ["clean"])
    }

    @Test func theLanguageModelReadsTheDictionarysWords() async {
        let rig = Rig()
        await rig.engine.set(text: "Скажи перекей\u{07}")
        rig.dictionary = { TextRules.replace($0, with: [DictionaryEntry(from: "перекей", to: "Perekey")]) }
        let modes = FakeModes(.refining())
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(modes.asked == ["Скажи Perekey"], "the dictionary's spelling, no control characters")
        #expect(rig.edits.map(\.text) == ["Привет, мир!"], "the rest of the rules edit the answer")
    }

    @Test func refiningShowsAndATapIsIgnored() async {
        let rig = Rig()
        let modes = FakeModes(.refining())
        modes.hangs = true
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .refining(.init(mode: "Чистовик", endpoint: "Ollama", isCloud: false)) })
        rig.controller.voice(.toggle)
        #expect(rig.state == .refining(1, .paste, raw: "Привет, мир."))
        #expect(rig.paster.pasted.isEmpty)
        rig.controller.voice(.cancel)
        #expect(await rig.until { rig.hud == .pastedFallback(.escape) })
    }

    @Test func escPastesTheRawText() async {
        let rig = Rig()
        let modes = FakeModes(.refining())
        modes.hangs = true
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { modes.asked.count == 1 })
        rig.controller.voice(.cancel)
        #expect(await rig.until { rig.hud == .pastedFallback(.escape) })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(await rig.until { modes.cancelled == 1 })
        #expect(rig.state == .idle)
        #expect(rig.sessionChanges == [true, false])
    }

    @Test func aTimeoutPastesTheRawText() async {
        let rig = Rig()
        let modes = FakeModes(.refining(timeout: .milliseconds(50)))
        modes.hangs = true
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pastedFallback(.timedOut) })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(await rig.until { modes.cancelled == 1 })
    }

    @Test func aFailurePastesTheRawText() async {
        let rig = Rig()
        let modes = FakeModes(.refining())
        modes.answer = nil
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pastedFallback(.failed) })
        #expect(rig.paster.pasted == ["Привет, мир."])
    }

    @Test func anAnswerInsteadOfAnEditPastesTheRawText() async {
        let rig = Rig()
        await rig.engine.set(text: "Какая завтра погода?")
        let modes = FakeModes(.refining())
        modes.answer = "Конечно! Завтра солнечно."
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pastedFallback(.answered) })
        #expect(rig.paster.pasted == ["Какая завтра погода?"])
    }

    @Test func aPasswordFieldNeverReachesTheLanguageModel() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureField
        rig.paster.result = .secureField
        let modes = FakeModes(.refining())
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(modes.asked.isEmpty)
    }

    @Test func aSkippedStepIsNamedAfterThePaste() async {
        let rig = Rig()
        let modes = FakeModes(DictationPlan(modeID: "mail", modeName: "Письмо",
                                            fallback: .needsConsent(host: "api.openai.com")))
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pastedFallback(.needsConsent(host: "api.openai.com")) })
        #expect(modes.asked.isEmpty)
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(modes.ended == ["mail"])
    }

    @Test func theModesSpeechModelHears() async {
        let rig = Rig()
        rig.controller.modes = FakeModes(DictationPlan(modeID: "x", modeName: "X", speechModel: "fake2",
                                                       speechHost: "api.groq.com"))
        await rig.startRecording()
        if case let .recording(recording) = rig.hud { #expect(recording.cloudHost == "api.groq.com") }
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Другая модель."])
        #expect(await rig.engine.heard.isEmpty)
    }

    @Test func copyOnly() async {
        let rig = Rig()
        rig.controller.modes = FakeModes(DictationPlan(modeID: "x", modeName: "X", output: .copy))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .copied })
        #expect(rig.paster.copied == ["Привет, мир."])
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.state == .idle)
    }

    @Test func pasteAndEnter() async {
        let rig = Rig()
        rig.controller.modes = FakeModes(DictationPlan(modeID: "x", modeName: "X", output: .pasteAndEnter))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.returns == 1)
    }

    @Test func noEnterAfterALanguageModelOrInATerminal() async {
        for plan in [DictationPlan(modeID: "x", modeName: "X", refine: .init(endpointName: "O", isCloud: false),
                                   output: .pasteAndEnter),
                     DictationPlan(modeID: "x", modeName: "X", output: .pasteAndEnter, singleLine: true)]
        {
            let rig = Rig()
            rig.controller.modes = FakeModes(plan)
            await rig.startRecording()
            rig.controller.voice(.toggle)
            #expect(await rig.until { rig.hud == .pasted })
            #expect(rig.paster.returns == 0)
        }
    }

    @Test func aTerminalTakesOneLine() async {
        let rig = Rig()
        await rig.engine.set(text: "git status\nrm -rf /")
        rig.controller.modes = FakeModes(DictationPlan(modeID: "terminal", modeName: "T", singleLine: true))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["git status rm -rf /"])
    }

    /// Voice on, the local model, a mode without a language model: not one
    /// request leaves, though the network gate is open for this Mac's servers.
    @Test func aLocalDictationMakesNoRequest() async throws {
        let fake = try await FakeOpenAI()
        VoiceNetworkPolicy.apply(isEnabled: true, managed: ManagedSettings(), modes: VoiceModeSet.defaults(), to: fake.http)
        fake.http.allowedOrigins = [.cloudLanguageModel: [fake.address.origin], .cloudSpeech: [fake.address.origin]]
        var set = VoiceModeSet.defaults()
        set.endpoints[set.endpoints.firstIndex { $0.id == "ollama" }!].address = fake.address.url("")
        set.modes[set.modes.firstIndex { $0.id == "message" }!].refine =
            RefineConfig(endpoint: "ollama", model: "qwen2.5:7b", prompt: "Short.")
        let front = VoiceModeRunner.Front(bundleID: "com.apple.Notes", name: "Notes")
        let runner = VoiceModeRunner(
            environment: .init(modes: { set }, front: { front }, host: { nil }, hasKey: { _ in false }, key: { _ in nil },
                               cloudDisabled: { false }, askConsent: { _ in }),
            client: fake.client())
        let rig = Rig()
        rig.controller.modes = runner
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(fake.http.requests.isEmpty)
        #expect(fake.server.requests.isEmpty)

        // The same Mac in a messenger: the mode with a language model reaches
        // the server on this Mac, once.
        set.bind(.app("com.apple.Notes"), to: "message")
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.paster.pasted.count == 2 })
        #expect(fake.http.requests.map(\.purpose) == [.cloudLanguageModel])
        #expect(fake.server.requests.count == 1)
    }
}

/// Cloud speech that fails, and what the dictation does then.
@MainActor
struct VoiceControllerCloudSpeechTests {
    let cloudPlan = DictationPlan(modeID: "x", modeName: "X", speechModel: "cloud:groq:whisper", speechHost: "api.groq.com")

    @Test func aFailingCloudFallsBackToThisMac() async {
        let rig = Rig()
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pastedFallback(.cloudSpeechFailed) })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(await rig.cloud.calls == 1)
        #expect(await rig.engine.heard == [16000])
        #expect(!rig.controller.canRetry)
    }

    @Test func withNothingOnThisMacTheAudioWaitsForRetry() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.controller.canRetry)
        #expect(DictationHUDPresentation(.failed(.cloudSpeech))?.buttons == [.retry])
        // The cloud is back: "Повторить" sends the same audio, and the text goes in.
        await rig.cloud.set(.answer("Облако вернулось."))
        rig.controller.retryLast()
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Облако вернулось."])
        #expect(await rig.cloud.calls == 2)
        #expect(!rig.controller.canRetry)
    }

    @Test func aRetryThatFailsKeepsTheAudio() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        rig.controller.retryLast()
        #expect(await rig.until { await rig.cloud.calls == 2 })
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        #expect(rig.controller.canRetry)
    }

    @Test func aPasswordFieldKeepsTheAudioHere() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureField
        rig.paster.result = .secureField
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(await rig.cloud.calls == 0)
        #expect(await rig.engine.heard == [16000])
    }

    @Test func secureInputKeepsTheAudioAndTheTextHere() async {
        let rig = Rig()
        var plan = cloudPlan
        plan.refine = .init(endpointName: "OpenAI", isCloud: true)
        let modes = FakeModes(plan)
        rig.controller.modes = modes
        await rig.startRecording()
        // Secure Input came on during the recording; the paste then refuses.
        rig.secureInput.allowsStart = false
        rig.paster.result = .secureInput(owner: nil)
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureInput(owner: nil)) })
        #expect(await rig.cloud.calls == 0)
        #expect(modes.asked.isEmpty, "nor the language model")
    }

    @Test func escStopsTheCloudRequest() async {
        let rig = Rig()
        await rig.cloud.set(.hang)
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { await rig.cloud.calls == 1 })
        rig.controller.voice(.cancel)
        #expect(rig.hud == .cancelled)
        #expect(await rig.until { await rig.cloud.cancelled == 1 })
        #expect(await rig.until { rig.controller.recognitionsDone == 1 })
        // Cancelled, not failed: no fallback, no retry, nothing pasted.
        #expect(rig.hud == .cancelled)
        #expect(rig.paster.pasted.isEmpty)
        #expect(await rig.engine.heard.isEmpty)
        #expect(!rig.controller.canRetry)
    }

    @Test func aPasswordIsNeverCopied() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureField
        rig.controller.modes = FakeModes(DictationPlan(modeID: "x", modeName: "X", output: .copy))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(rig.paster.copied.isEmpty)
        #expect(rig.controller.last?.isPrivate == true)
        #expect(DictationHUDPresentation(.notPasted(.secureField))?.buttons.isEmpty == true)
    }

    @Test func enterGoesOnlyToTheAppStillInFront() async {
        var front: pid_t? = 42
        var posted = 0
        let lost = await TextPasterAdapter.pressReturn(pid: 42, frontmost: { front },
                                                       wait: { front = 7 }, post: { posted += 1 })
        #expect(lost == .targetChanged)
        #expect(posted == 0)
        front = 42
        let kept = await TextPasterAdapter.pressReturn(pid: 42, frontmost: { front }, wait: {}, post: { posted += 1 })
        #expect(kept == .pasted)
        #expect(posted == 1)
        front = 3
        #expect(await TextPasterAdapter.pressReturn(pid: 42, frontmost: { front }, wait: {}, post: { posted += 1 })
            == .targetChanged)
        #expect(posted == 1)
    }

    @Test func cloudTextIsCleanedInAnyMode() async {
        let rig = Rig()
        await rig.cloud.set(.answer("git status\u{1B}[201~rm -rf ~\u{0F}"))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["git status[201~rm -rf ~"])
    }

    @Test func aRetryIntoAPasswordFieldStaysHere() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        // The field turned out to be a password one: no model here, no cloud.
        rig.paster.targetPrivacy = .secureField
        await rig.cloud.set(.answer("секрет"))
        rig.controller.retryLast()
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(await rig.cloud.calls == 1)
        #expect(!rig.controller.canRetry)
        #expect(rig.paster.pasted.isEmpty)
    }

    @Test func aRetryUnderSecureInputUsesThisMac() async {
        let rig = Rig()
        // The cloud failed and this Mac had no model then; now Secure Input is on.
        let modes = FakeModes(cloudPlan)
        rig.controller.modes = modes
        await rig.startRecording()
        rig.controller.apply(DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        rig.controller.apply(DictationPreferences(modelID: "fake", silenceStop: nil))
        rig.secureInput.allowsStart = false
        rig.controller.retryLast()
        #expect(await rig.until { rig.paster.pasted == ["Привет, мир."] })
        #expect(await rig.cloud.calls == 1)
    }

    @Test func aRetryGoesWhereTheModeSendsIt() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        var plan = cloudPlan
        plan.output = .copy
        rig.controller.modes = FakeModes(plan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        await rig.cloud.set(.answer("В буфер."))
        rig.controller.retryLast()
        #expect(await rig.until { rig.hud == .copied })
        #expect(rig.paster.copied == ["В буфер."])
        #expect(rig.paster.pasted.isEmpty, "not into the field")
    }

    @Test func aNewDictationCancelsTheRetry() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        await rig.cloud.set(.hang)
        rig.controller.retryLast()
        #expect(await rig.until { await rig.cloud.calls == 2 })
        // A new dictation, on this Mac's model now.
        rig.controller.apply(DictationPreferences(modelID: "fake", silenceStop: nil))
        rig.controller.modes = nil
        await rig.startRecording()
        #expect(await rig.until { await rig.cloud.cancelled == 1 })
        #expect(!rig.controller.canRetry)
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир."])
    }

    @Test func aRetryANewDictationCancelledPastesAndRecordsNothing() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        await rig.cloud.set(.answer("Старый текст."))
        // The retry has its text and reads the caret: a new dictation starts then.
        let gate = Gate()
        rig.paster.contextWaits = { await gate.wait() }
        rig.controller.retryLast()
        #expect(await rig.until { gate.isWaiting })
        rig.paster.contextWaits = nil
        rig.controller.apply(DictationPreferences(modelID: "fake", silenceStop: nil))
        rig.controller.modes = nil
        await rig.startRecording()
        gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.paster.pasted.isEmpty)
        #expect(rig.records.isEmpty)
        guard case .recording = rig.hud else {
            Issue.record("the new session's HUD: \(rig.hud)")
            return
        }
        // The new dictation goes in as usual: one paste, one entry.
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == ["Привет, мир."])
        #expect(await rig.until { rig.records.count == 1 })
    }

    @Test func turningVoiceOffDropsTheKeptAudio() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        #expect(rig.controller.canRetry)
        await rig.controller.shutdown()
        #expect(!rig.controller.canRetry)
    }

    // MARK: The history

    @Test func aCloudDictationIsRecordedWithTheCloudModel() async {
        let rig = Rig()
        rig.prompt = "Perekey, Parakeet"
        await rig.cloud.set(.answer("Из облака."))
        var plan = cloudPlan
        plan.host = "mail.google.com"
        rig.controller.modes = FakeModes(plan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.records.count == 1 })
        let record = rig.records[0]
        #expect(record.model == "cloud:groq:whisper")
        #expect(record.text == "Из облака." && record.pasted)
        #expect(record.host == "mail.google.com", "the history's excluded sites see it")
        #expect(await rig.cloud.prompts == ["Perekey, Parakeet"], "the dictionary goes to the cloud too")
    }

    @Test func aCloudFallbackIsRecordedWithThisMacsModel() async {
        let rig = Rig()
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.records.count == 1 })
        #expect(rig.records[0].model == "fake")
    }

    @Test func aPrivateCloudDictationIsNotRecorded() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .secureField
        rig.paster.result = .secureField
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .notPasted(.secureField) })
        #expect(await rig.until { rig.state == .idle })
        #expect(rig.records.isEmpty)
    }

    @Test func anUnknownTargetReachesTheCloudButNotTheHistory() async {
        let rig = Rig()
        rig.paster.targetPrivacy = .unknown
        await rig.cloud.set(.answer("Из облака."))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(await rig.cloud.calls == 1)
        #expect(rig.paster.pasted == ["Из облака."])
        #expect(rig.records.isEmpty)
    }

    @Test func aRetryAfterTheCloudFailedWritesOneEntry() async {
        let rig = Rig(preferences: DictationPreferences(modelID: "not-downloaded", silenceStop: nil))
        rig.controller.modes = FakeModes(cloudPlan)
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .failed(.cloudSpeech) })
        #expect(rig.records.isEmpty, "nothing heard yet")
        await rig.cloud.set(.answer("Облако вернулось."))
        rig.controller.retryLast()
        #expect(await rig.until { rig.records.count == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.records.count == 1)
        let record = rig.records[0]
        #expect(record.text == "Облако вернулось." && record.pasted)
        #expect(record.model == "cloud:groq:whisper")
        #expect(record.audio?.count == 16000)
    }

    @Test func theTextRulesComeFirstThenTheFilterThenOneLine() async {
        let rig = Rig()
        rig.editor = { _, _ in " ls\u{1B}[201~\n-la" }
        rig.controller.modes = FakeModes(
            DictationPlan(modeID: "terminal", modeName: "Терминал", singleLine: true, removesFillers: false))
        await rig.startRecording()
        rig.controller.voice(.toggle)
        #expect(await rig.until { rig.hud == .pasted })
        #expect(rig.paster.pasted == [" ls[201~ -la"])
        #expect(rig.fillerRules == [false], "the mode's filler words rule")
        #expect(await rig.until { rig.records.count == 1 })
        #expect(rig.records[0].text == " ls[201~ -la", "the history keeps what went in")
    }
}

/// Holds an await until the test opens it.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
