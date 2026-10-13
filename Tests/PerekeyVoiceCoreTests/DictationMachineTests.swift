// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyVoiceCore
import Testing

typealias Machine = DictationMachine

/// Runs inputs through a fresh machine; the outputs of the last one and the state after it.
private func run(_ inputs: [Machine.Input], secureInput: Bool = false) -> (out: [Machine.Output], state: Machine.State) {
    var machine = Machine(secureInput: secureInput)
    var out: [Machine.Output] = []
    for input in inputs {
        out = machine.handle(input)
    }
    return (out, machine.state)
}

private let tap = Machine.Input.voice(.toggle)
private let esc = Machine.Input.voice(.cancel)
private let holdDown = Machine.Input.voice(.holdBegan)
private let holdUp = Machine.Input.voice(.holdEnded(reason: .released))
private let holdLost = Machine.Input.voice(.holdEnded(reason: .lost))
private let started = Machine.Input.captureStarted(1)
private let hello = Machine.Input.recognized(1, .text("привет"))

private func stops(_ session: Machine.Session = 1, _ delivery: Machine.Delivery = .paste) -> [Machine.Output] {
    [.stopCapture(session), .sound(.stop), .phase(.recognizing), .recognize(session, delivery)]
}

private func holdStops(_ session: Machine.Session = 1) -> [Machine.Output] {
    [.stopCapture(session), .sound(.stop), .watchHold(false), .phase(.recognizing), .recognize(session, .paste)]
}

private let cancels: [Machine.Output] = [.discard(1), .sessionActive(false), .phase(.cancelled)]

struct DictationMachineTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let inputs: [Machine.Input]
        let out: [Machine.Output]
        let state: Machine.State
        var secureInput = false

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // Idle
        Case(name: "tap starts", inputs: [tap],
             out: [.sessionActive(true), .phase(.starting), .startCapture(1)],
             state: .starting(1, .tap, pending: nil)),
        Case(name: "hold starts and watches its keys", inputs: [holdDown],
             out: [.sessionActive(true), .phase(.starting), .startCapture(1), .watchHold(true)],
             state: .starting(1, .hold, pending: nil)),
        Case(name: "Esc while idle", inputs: [esc], out: [], state: .idle),
        Case(name: "hold up while idle", inputs: [holdUp], out: [], state: .idle),
        Case(name: "Secure Input keeps the tap silent", inputs: [tap], out: [], state: .idle, secureInput: true),
        Case(name: "Secure Input keeps the hold silent", inputs: [holdDown], out: [], state: .idle, secureInput: true),
        Case(name: "Secure Input off again", inputs: [.secureInputChanged(false), tap],
             out: [.sessionActive(true), .phase(.starting), .startCapture(1)],
             state: .starting(1, .tap, pending: nil), secureInput: true),
        Case(name: "nothing to stop while idle", inputs: [.sleep, .sessionLost, .accessibilityLost],
             out: [], state: .idle),

        // Starting
        Case(name: "microphone started", inputs: [tap, started],
             out: [.sound(.start), .phase(.recording)], state: .recording(1, .tap)),
        Case(name: "tap while starting is queued", inputs: [tap, tap],
             out: [], state: .starting(1, .tap, pending: .stop(.trigger))),
        Case(name: "stop while starting runs after the start", inputs: [tap, tap, started],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "Esc while starting is queued", inputs: [tap, esc],
             out: [], state: .starting(1, .tap, pending: .cancel(.escape))),
        Case(name: "Esc while starting cancels after the start", inputs: [tap, esc, started],
             out: cancels, state: .idle),
        Case(name: "Esc wins over a queued stop", inputs: [tap, tap, esc, started],
             out: cancels, state: .idle),
        Case(name: "a stop does not undo a queued Esc", inputs: [tap, esc, tap, started],
             out: cancels, state: .idle),
        Case(name: "sleep while starting", inputs: [tap, .sleep, started],
             out: [.discard(1), .sessionActive(false), .phase(.cancelled)], state: .idle),
        Case(name: "hold up while starting", inputs: [holdDown, holdUp, started],
             out: holdStops(), state: .recognizing(1, .paste)),
        Case(name: "lost hold while starting", inputs: [holdDown, holdLost],
             out: [], state: .starting(1, .hold, pending: .stop(.holdLost))),
        Case(name: "no microphone permission", inputs: [tap, .captureFailed(1, .notAuthorized)],
             out: [.sessionActive(false), .phase(.captureFailed(.notAuthorized))], state: .idle),
        Case(name: "hold start failed", inputs: [holdDown, .captureFailed(1, .noMicrophone)],
             out: [.watchHold(false), .sessionActive(false), .phase(.captureFailed(.noMicrophone))], state: .idle),
        Case(name: "Secure Input while starting", inputs: [tap, .secureInputChanged(true), started],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "Accessibility lost while starting", inputs: [tap, .accessibilityLost, started],
             out: stops(1, .keep), state: .recognizing(1, .keep)),
        Case(name: "a second hold down while starting", inputs: [holdDown, holdDown],
             out: [], state: .starting(1, .hold, pending: nil)),

        // Recording
        Case(name: "tap stops and recognizes", inputs: [tap, started, tap],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "hold up stops", inputs: [holdDown, started, holdUp],
             out: holdStops(), state: .recognizing(1, .paste)),
        Case(name: "lost hold stops too", inputs: [holdDown, started, holdLost],
             out: holdStops(), state: .recognizing(1, .paste)),
        Case(name: "a tap does not end a hold", inputs: [holdDown, started, tap],
             out: [], state: .recording(1, .hold)),
        Case(name: "a hold up does not end a tap session", inputs: [tap, started, holdUp],
             out: [], state: .recording(1, .tap)),
        Case(name: "Esc cancels", inputs: [tap, started, esc], out: cancels, state: .idle),
        Case(name: "Esc cancels a hold", inputs: [holdDown, started, esc],
             out: [.discard(1), .watchHold(false), .sessionActive(false), .phase(.cancelled)], state: .idle),
        Case(name: "silence stops", inputs: [tap, started, .captureEnded(1, .silence)],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "ten minutes stop", inputs: [tap, started, .captureEnded(1, .limit)],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "a device change recognizes what was said", inputs: [tap, started, .captureEnded(1, .deviceChanged)],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "sleep cancels", inputs: [tap, started, .sleep], out: cancels, state: .idle),
        Case(name: "a locked screen stops and recognizes", inputs: [tap, started, .sessionLost],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "Accessibility lost: the text is only kept", inputs: [tap, started, .accessibilityLost],
             out: stops(1, .keep), state: .recognizing(1, .keep)),
        Case(name: "Secure Input in the middle stops and recognizes", inputs: [tap, started, .secureInputChanged(true)],
             out: stops(), state: .recognizing(1, .paste)),
        Case(name: "an old session's end is ignored", inputs: [tap, started, .captureEnded(7, .silence)],
             out: [], state: .recording(1, .tap)),

        // Recognizing
        Case(name: "tap while recognizing", inputs: [tap, started, tap, tap],
             out: [.phase(.stillRecognizing)], state: .recognizing(1, .paste)),
        Case(name: "hold down while recognizing", inputs: [holdDown, started, holdUp, holdDown],
             out: [.phase(.stillRecognizing)], state: .recognizing(1, .paste)),
        Case(name: "Esc while recognizing drops the result", inputs: [tap, started, tap, esc],
             out: cancels, state: .idle),
        Case(name: "the dropped result is ignored", inputs: [tap, started, tap, esc, hello],
             out: [], state: .idle),
        Case(name: "text goes to the paste", inputs: [tap, started, tap, hello],
             out: [.phase(.pasting), .paste(1, "привет")], state: .pasting(1)),
        Case(name: "no speech", inputs: [tap, started, tap, .recognized(1, .noSpeech)],
             out: [.sessionActive(false), .phase(.nothingHeard)], state: .idle),
        Case(name: "only made-up phrases", inputs: [tap, started, tap, .recognized(1, .nothingLeft)],
             out: [.sessionActive(false), .phase(.nothingHeard)], state: .idle),
        Case(name: "kept text", inputs: [tap, started, .accessibilityLost, hello],
             out: [.sessionActive(false), .keep(1, "привет")], state: .idle),
        Case(name: "Accessibility lost while recognizing", inputs: [tap, started, tap, .accessibilityLost, hello],
             out: [.sessionActive(false), .keep(1, "привет")], state: .idle),
        Case(name: "recognition failed", inputs: [tap, started, tap, .recognitionFailed(1, "boom")],
             out: [.sessionActive(false), .phase(.recognitionFailed("boom"))], state: .idle),
        Case(name: "sleep while recognizing", inputs: [tap, started, tap, .sleep],
             out: [], state: .recognizing(1, .paste)),
        Case(name: "another session's text", inputs: [tap, started, tap, .recognized(2, .text("x"))],
             out: [], state: .recognizing(1, .paste)),

        // Pasting
        Case(name: "pasted", inputs: [tap, started, tap, hello, .pasted(1)],
             out: [.sessionActive(false)], state: .idle),
        Case(name: "tap while pasting", inputs: [tap, started, tap, hello, tap], out: [], state: .pasting(1)),
        Case(name: "Esc while pasting", inputs: [tap, started, tap, hello, esc], out: [], state: .pasting(1)),
        Case(name: "Secure Input while pasting", inputs: [tap, started, tap, hello, .secureInputChanged(true)],
             out: [], state: .pasting(1)),
        Case(name: "another session's paste", inputs: [tap, started, tap, hello, .pasted(3)],
             out: [], state: .pasting(1)),
    ]

    @Test(arguments: cases) func transition(_ test: Case) {
        let result = run(test.inputs, secureInput: test.secureInput)
        #expect(result.out == test.out)
        #expect(result.state == test.state)
    }

    @Test func sessionsAreNumbered() {
        var machine = Machine()
        _ = machine.handle(tap)
        _ = machine.handle(esc)
        _ = machine.handle(started)
        #expect(machine.state == .idle)
        #expect(machine.handle(tap) == [.sessionActive(true), .phase(.starting), .startCapture(2)])
        // The first session's late answers do nothing to the second.
        #expect(machine.handle(.captureStarted(1)) == [])
        #expect(machine.handle(.recognized(1, .text("old"))) == [])
        #expect(machine.handle(.captureStarted(2)) == [.sound(.start), .phase(.recording)])
        #expect(machine.session == 2)
    }

    @Test func escDuringRecognitionThenANewSession() {
        var machine = Machine()
        for input in [tap, started, tap, esc] {
            _ = machine.handle(input)
        }
        _ = machine.handle(tap)
        _ = machine.handle(.captureStarted(2))
        _ = machine.handle(tap)
        // The first recognition finishes late: dropped.
        #expect(machine.handle(hello) == [])
        #expect(machine.handle(.recognized(2, .text("новое"))) == [.phase(.pasting), .paste(2, "новое")])
    }

    @Test func secureInputIsRemembered() {
        var machine = Machine()
        _ = machine.handle(.secureInputChanged(true))
        #expect(machine.secureInput)
        #expect(machine.handle(tap) == [])
        _ = machine.handle(.secureInputChanged(false))
        #expect(machine.handle(tap).contains(.startCapture(1)))
    }
}
