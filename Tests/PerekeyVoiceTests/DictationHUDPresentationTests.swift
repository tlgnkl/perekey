// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyVoice
import Testing

@Suite struct DictationHUDPresentationTests {
    private func present(_ state: DictationHUDState, hasText: Bool = true) -> DictationHUDPresentation? {
        DictationHUDPresentation(state, hasText: hasText)
    }

    @Test func hiddenShowsNothing() {
        #expect(present(.hidden) == nil)
    }

    @Test func startingShowsTheMeterAtZeroAndCancel() throws {
        let hud = try #require(present(.starting))
        #expect(hud.message == .starting)
        #expect(hud.meter?.level == 0 && hud.meter?.timerText == "0:00")
        #expect(hud.buttons == [.cancel])
        #expect(hud.hidesAfter == nil)
    }

    @Test func recordingShowsLevelTimerAndCancel() throws {
        let hud = try #require(present(.recording(.init(seconds: 7.9, level: 0.4, preparingModel: false))))
        #expect(hud.message == .recording)
        #expect(hud.meter == .init(level: 0.4, seconds: 7.9))
        #expect(hud.meter?.timerText == "0:07")
        #expect(hud.buttons == [.cancel])
        #expect(hud.hidesAfter == nil)
    }

    @Test func theTimerReadsMinutesAndSeconds() {
        #expect(DictationHUDPresentation.Meter(level: 0, seconds: 60).timerText == "1:00")
        #expect(DictationHUDPresentation.Meter(level: 0, seconds: 125.5).timerText == "2:05")
        #expect(DictationHUDPresentation.Meter(level: 0, seconds: 754).timerText == "12:34")
        #expect(DictationHUDPresentation.Meter(level: 0, seconds: -1).timerText == "0:00")
    }

    @Test func theLevelStaysInRange() throws {
        let loud = try #require(present(.recording(.init(seconds: 1, level: 3, preparingModel: false))))
        let quiet = try #require(present(.recording(.init(seconds: 1, level: -1, preparingModel: false))))
        #expect(loud.meter?.level == 1 && quiet.meter?.level == 0)
    }

    @Test func aModelStillLoadingSaysSoWhileRecordingAndRecognizing() throws {
        let recording = try #require(present(.recording(.init(seconds: 2, level: 0.2, preparingModel: true))))
        #expect(recording.message == .preparingModel)
        #expect(recording.meter != nil, "the person still sees that the microphone hears")
        #expect(present(.recognizing(preparingModel: true))?.message == .preparingModel)
        #expect(present(.recognizing(preparingModel: false))?.message == .recognizing)
    }

    @Test func recognizingAndStillRecognizingCanBeCancelled() {
        #expect(present(.recognizing(preparingModel: false))?.buttons == [.cancel])
        #expect(present(.recognizing(preparingModel: true))?.buttons == [.cancel])
        #expect(present(.stillRecognizing)?.message == .stillRecognizing)
        #expect(present(.stillRecognizing)?.buttons == [.cancel])
        #expect(present(.recognizing(preparingModel: false))?.meter == nil)
    }

    @Test func pastingHasNoButtons() {
        #expect(present(.pasting)?.message == .pasting)
        #expect(present(.pasting)?.buttons == [])
    }

    @Test func pastedIsShortAndGoes() {
        let hud = present(.pasted)
        #expect(hud?.message == .pasted)
        #expect(hud?.buttons == [])
        #expect(hud?.hidesAfter == DictationHUDPresentation.Lifetime.confirmation)
    }

    @Test func notPastedOffersPasteAndCopy() {
        for reason in [NotPastedReason.targetChanged, .failed("boom")] {
            let hud = present(.notPasted(reason))
            #expect(hud?.message == .notPasted)
            #expect(hud?.buttons == [.paste, .copy])
            #expect(hud?.hidesAfter == DictationHUDPresentation.Lifetime.notPasted)
        }
    }

    @Test func aTimeoutOffersOnlyCopy() {
        let hud = present(.notPasted(.timedOut))
        #expect(hud?.message == .timedOut)
        #expect(hud?.buttons == [.copy])
    }

    @Test func aPasswordFieldNamesItselfAndOffersNothingToDoWithTheText() {
        let hud = present(.notPasted(.secureField))
        #expect(hud?.message == .secureField)
        #expect(hud?.buttons == [], "the text meant for a password stays off the pasteboard")
    }

    @Test func secureInputNamesItsOwner() {
        let named = present(.notPasted(.secureInput(owner: "Terminal")))
        #expect(named?.message == .secureInput(owner: "Terminal"))
        #expect(named?.buttons == [], "a protected app's text is neither pasted again nor copied")
        #expect(present(.notPasted(.secureInput(owner: nil)))?.message == .secureInput(owner: nil))
    }

    @Test func withoutAccessibilityTheTextCanBeCopiedAndTheAccessFixed() {
        let hud = present(.notPasted(.noAccessibility))
        #expect(hud?.message == .noAccessibility)
        #expect(hud?.buttons == [.copy, .openAccessibilitySettings])
    }

    @Test func aTextThatIsGoneOffersNoButtons() {
        #expect(present(.notPasted(.targetChanged), hasText: false)?.buttons == [])
        #expect(present(.notPasted(.noAccessibility), hasText: false)?.buttons == [.openAccessibilitySettings])
    }

    @Test func offeringPasteFollowsTheReason() {
        let reasons: [NotPastedReason] = [.targetChanged, .noAccessibility, .timedOut, .failed("x")]
        for reason in reasons {
            let offers = present(.notPasted(reason))?.buttons.contains(.paste)
            #expect(offers == reason.offersPaste, "\(reason)")
        }
    }

    @Test func privateTextsGetNoPasteAndNoCopy() {
        for reason in [NotPastedReason.secureField, .secureInput(owner: "Terminal"), .secureInput(owner: nil)] {
            let buttons = present(.notPasted(reason))?.buttons ?? [.copy]
            #expect(!buttons.contains(.paste) && !buttons.contains(.copy), "\(reason)")
        }
    }

    @Test func nothingHeardAndCancelledGoByThemselves() {
        #expect(present(.nothingHeard)?.message == .nothingHeard)
        #expect(present(.nothingHeard)?.hidesAfter == DictationHUDPresentation.Lifetime.notice)
        #expect(present(.cancelled)?.message == .cancelled)
        #expect(present(.cancelled)?.hidesAfter == DictationHUDPresentation.Lifetime.confirmation)
        #expect(present(.cancelled)?.buttons == [])
    }

    @Test func aDeniedMicrophoneOffersItsSettings() {
        let hud = present(.failed(.microphoneDenied))
        #expect(hud?.message == .microphoneDenied)
        #expect(hud?.buttons == [.openMicrophoneSettings])
        #expect(hud?.hidesAfter == DictationHUDPresentation.Lifetime.error)
    }

    @Test func otherFailuresNameTheirCause() {
        #expect(present(.failed(.noMicrophone))?.message == .noMicrophone)
        #expect(present(.failed(.microphone("x")))?.message == .microphoneFailed)
        #expect(present(.failed(.model("x")))?.message == .modelFailed)
        #expect(present(.failed(.model("x")))?.buttons == [.openVoiceSettings])
        #expect(present(.failed(.recognition("x")))?.message == .recognitionFailed)
        // The system's own wording of an error is not shown.
        #expect(present(.failed(.recognition("a long engine error")))?.buttons == [])
    }

    @Test func everyFinalStateHasALifetimeAndOthersDoNot() {
        let running: [DictationHUDState] = [.starting, .recording(.init(seconds: 0, level: 0, preparingModel: false)),
                                            .recognizing(preparingModel: false), .stillRecognizing, .pasting]
        for state in running { #expect(present(state)?.hidesAfter == nil, "\(state)") }
        let final: [DictationHUDState] = [.pasted, .nothingHeard, .cancelled, .notPasted(.targetChanged),
                                          .failed(.microphoneDenied), .failed(.noMicrophone), .failed(.model("x"))]
        for state in final { #expect(present(state)?.hidesAfter != nil, "\(state)") }
    }

    @Test func theModeAndTheCloudAreReservedAndEmpty() throws {
        let hud = try #require(present(.recording(.init(seconds: 1, level: 0, preparingModel: false))))
        #expect(!hud.cloud && hud.modeName == nil)
    }

    // MARK: VoiceOver

    @Test func theTimerAndTheLevelDoNotAnnounceAgain() {
        let first = present(.recording(.init(seconds: 1, level: 0.1, preparingModel: false)))
        let next = present(.recording(.init(seconds: 2, level: 0.9, preparingModel: false)))
        #expect(DictationHUDPresentation.announces(first, after: nil))
        #expect(!DictationHUDPresentation.announces(next, after: first))
    }

    @Test func aChangeOfMessageAnnounces() {
        let recording = present(.recording(.init(seconds: 5, level: 0.1, preparingModel: false)))
        let recognizing = present(.recognizing(preparingModel: false))
        let pasted = present(.pasted)
        #expect(DictationHUDPresentation.announces(recognizing, after: recording))
        #expect(DictationHUDPresentation.announces(pasted, after: recognizing))
        #expect(DictationHUDPresentation.announces(present(.starting), after: nil))
        // Loading ends while recording: the message changes.
        let loading = present(.recording(.init(seconds: 3, level: 0.1, preparingModel: true)))
        #expect(DictationHUDPresentation.announces(recording, after: loading))
    }

    @Test func secureInputOfAnotherAppAnnouncesItsOwner() {
        let terminal = present(.notPasted(.secureInput(owner: "Terminal")))
        let other = present(.notPasted(.secureInput(owner: "Notes")))
        #expect(DictationHUDPresentation.announces(other, after: terminal))
    }

    @Test func hidingAnnouncesNothing() {
        #expect(!DictationHUDPresentation.announces(nil, after: present(.pasted)))
        #expect(!DictationHUDPresentation.announces(nil, after: nil))
    }

    @Test func modesShowTheirNameAndTheCloud() throws {
        let recording = try #require(present(.recording(.init(seconds: 2, level: 0.3, preparingModel: false,
                                                              mode: "Письмо", cloudHost: "api.openai.com"))))
        #expect(recording.modeName == "Письмо")
        #expect(recording.cloud)
        let refining = try #require(present(.refining(.init(mode: "Сообщение", endpoint: "Ollama", isCloud: false))))
        #expect(refining.message == .refining)
        #expect(refining.buttons == [.pasteAsSaid])
        #expect(refining.modeName == "Сообщение")
        #expect(refining.endpointName == "Ollama")
        #expect(!refining.cloud)
        #expect(refining.hidesAfter == nil)
        #expect(present(.refining(.init(mode: "Письмо", endpoint: "OpenAI", isCloud: true)))?.cloud == true)
    }

    @Test func theRawTextSaysWhy() {
        #expect(present(.pastedFallback(.escape))?.message == .pastedAsSaid(.escape))
        #expect(present(.pastedFallback(.escape))?.hidesAfter == DictationHUDPresentation.Lifetime.confirmation)
        #expect(present(.pastedFallback(.answered))?.hidesAfter == DictationHUDPresentation.Lifetime.notice)
        #expect(present(.pastedFallback(.needsConsent(host: "api.openai.com")))?.message
            == .pastedAsSaid(.needsConsent(host: "api.openai.com")))
        #expect(present(.copied)?.message == .copied)
    }
}
