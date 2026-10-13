// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct VoiceIntroTests {
    /// An existing user who has not met voice yet, on a Mac that runs it.
    private func situation(_ change: (inout VoiceIntro.Situation) -> Void = { _ in }) -> VoiceIntro.Situation {
        var base = VoiceIntro.Situation(onboardingDone: true, answered: false, voiceIsOn: false, isSupported: true,
                                        disabledByProfile: false, fileIsLocked: false, hasAccess: true)
        change(&base)
        return base
    }

    @Test func anExistingUserGetsTheWindow() {
        #expect(VoiceIntro.offer(situation()) == .window)
    }

    @Test func aNewUserGetsAStepOfTheFirstRunWindow() {
        #expect(VoiceIntro.offer(situation { $0.onboardingDone = false }) == .onboardingStep)
        // Access is the step before it: the step does not wait for it.
        #expect(VoiceIntro.offer(situation { $0.onboardingDone = false; $0.hasAccess = false }) == .onboardingStep)
    }

    @Test func itShowsOnce() {
        #expect(VoiceIntro.offer(situation { $0.answered = true }) == .none)
        #expect(VoiceIntro.offer(situation { $0.onboardingDone = false; $0.answered = true }) == .none)
    }

    @Test func nothingOnAMacThatCannotRunVoice() {
        #expect(VoiceIntro.offer(situation { $0.isSupported = false }) == .none)
        #expect(VoiceIntro.offer(situation { $0.onboardingDone = false; $0.isSupported = false }) == .none)
    }

    @Test func nothingUnderAProfileThatTurnsVoiceOff() {
        #expect(VoiceIntro.offer(situation { $0.disabledByProfile = true }) == .none)
        #expect(VoiceIntro.offer(situation { $0.onboardingDone = false; $0.disabledByProfile = true }) == .none)
    }

    @Test func nothingWhenVoiceIsOnAlready() {
        #expect(VoiceIntro.offer(situation { $0.voiceIsOn = true }) == .none)
    }

    @Test func nothingOverAFileOfANewerVersion() {
        #expect(VoiceIntro.offer(situation { $0.fileIsLocked = true }) == .none)
    }

    @Test func theWindowWaitsForAccessibility() {
        #expect(VoiceIntro.offer(situation { $0.hasAccess = false }) == .none)
    }

    @Test func theAnswerIsInTheFileAndOffByDefault() throws {
        #expect(!VoiceSettings().introAnswered)
        let old = Data(#"{"schemaVersion":1,"isEnabled":false}"#.utf8)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: old).introAnswered == false)
        let answered = VoiceSettings(introAnswered: true)
        let data = try JSONEncoder().encode(answered)
        #expect(try JSONDecoder().decode(VoiceSettings.self, from: data).introAnswered)
        // An unreadable value counts as "not answered" and is kept until the person answers.
        var broken = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"introAnswered":"yes"}"#.utf8))
        #expect(!broken.introAnswered && broken.unreadableKeys == ["introAnswered"])
        broken.introAnswered = true
        #expect(broken.unreadableKeys.isEmpty)
    }
}
