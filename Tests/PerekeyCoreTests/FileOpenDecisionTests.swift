// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct FileOpenDecisionTests {
    private func decide(media: Bool = true, _ voice: VoiceAvailability, ready: Bool, late: Bool = false) -> FileOpenDecision {
        FileOpenDecision.decide(hasMedia: media, voice: voice, queueReady: ready, waitedTooLong: late)
    }

    @Test func aReadyQueueTakesTheFiles() {
        #expect(decide(.on, ready: true) == .enqueue)
    }

    @Test func aColdStartHoldsThemUntilTheQueueComes() {
        #expect(decide(.on, ready: false) == .hold)
    }

    @Test func aQueueThatNeverComesRefuses() {
        #expect(decide(.on, ready: false, late: true) == .refuse(.notReady))
    }

    @Test func voiceOffRefusesAndSettingsCanHelp() {
        #expect(decide(.off, ready: false) == .refuse(.voiceOff))
        #expect(FileOpenDecision.Refusal.voiceOff.settingsCanHelp)
    }

    @Test func voiceWithoutAShortcutRefusesAtOnceAndSettingsCanHelp() {
        #expect(decide(.noShortcut, ready: false) == .refuse(.noShortcut))
        #expect(FileOpenDecision.Refusal.noShortcut.settingsCanHelp)
    }

    @Test func unavailableVoiceRefusesAndSettingsCannotHelp() {
        #expect(decide(.unavailable, ready: false) == .refuse(.voiceUnavailable))
        #expect(!FileOpenDecision.Refusal.voiceUnavailable.settingsCanHelp)
        #expect(!FileOpenDecision.Refusal.notReady.settingsCanHelp)
    }

    @Test func aFileThatIsNotMediaIsRefusedFirst() {
        #expect(decide(media: false, .on, ready: true) == .refuse(.notMedia))
        #expect(decide(media: false, .off, ready: false) == .refuse(.notMedia))
    }

    @Test func aDeadlineNeverBeatsAReadyQueue() {
        #expect(decide(.on, ready: true, late: true) == .enqueue)
    }
}
