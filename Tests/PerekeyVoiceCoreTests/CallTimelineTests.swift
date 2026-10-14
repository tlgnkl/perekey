// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyVoiceCore
import Testing

@Suite struct CallTimelineTests {
    /// One tick a millisecond, so the numbers read as time.
    private func timeline() -> CallTimeline {
        CallTimeline(startHostTime: 10_000, ticksPerSecond: 1000)
    }

    @Test func scaleIsHostTimeFromTheStart() {
        let line = timeline()
        #expect(line.offset(of: 10_000) == 0)
        #expect(line.offset(of: 12_500) == 2.5)
        // A block stamped before the start lands on its first second.
        #expect(line.offset(of: 9_000) == 0)
    }

    @Test func pausesAreLeftOut() {
        var line = timeline()
        let paused = line.pause(at: 12_000)
        let pausedAgain = line.pause(at: 12_500)
        #expect(paused && !pausedAgain)
        #expect(line.isPaused)
        // The scale stands still while it lasts.
        #expect(line.offset(of: 13_000) == 2)
        let resumed = line.resume(at: 15_000)
        let resumedAgain = line.resume(at: 15_500)
        #expect(resumed && !resumedAgain)
        #expect(line.offset(of: 16_000) == 3)
        line.pause(at: 17_000)
        line.resume(at: 20_000)
        #expect(line.offset(of: 21_000) == 5)
        // Older times keep their place.
        #expect(line.offset(of: 11_000) == 1)
        #expect(line.offset(of: 16_500) == 3.5)
    }

    @Test func audioGoesOnlyWhenItsTermSays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func call(_ state: RecordingMeta.State, daysAgo: Double) -> RecordingMeta {
            var meta = RecordingMeta.call(source: .system, startHostTime: 1,
                                          createdAt: now.addingTimeInterval(-daysAgo * 86400), audioRetention: .always)
            meta.state = state
            meta.segments = [.init(track: .mic, file: "mic-0001.aac", startHostTime: 1, startOffset: 0)]
            return meta
        }
        let always = CallAudioPolicy(retention: .always, keepDisabled: false)
        let month = CallAudioPolicy(retention: .month, keepDisabled: false)
        let untilDone = CallAudioPolicy(retention: .untilTranscribed, keepDisabled: false)
        let profile = CallAudioPolicy(retention: .always, keepDisabled: true)

        #expect(!always.removesAudio(of: call(.done, daysAgo: 400), now: now))
        #expect(month.removesAudio(of: call(.done, daysAgo: 30), now: now))
        #expect(!month.removesAudio(of: call(.done, daysAgo: 29), now: now))
        // Not transcribed, the audio is all there is: it stays past any term.
        #expect(!month.removesAudio(of: call(.stopped, daysAgo: 90), now: now))
        #expect(untilDone.removesAudio(of: call(.done, daysAgo: 0), now: now))
        #expect(!untilDone.removesAudio(of: call(.stopped, daysAgo: 0), now: now))
        #expect(profile.effective == .untilTranscribed)
        #expect(profile.removesAudio(of: call(.done, daysAgo: 0), now: now))
        // Never while it records or waits for the queue, never twice, never a file.
        #expect(!month.removesAudio(of: call(.recording, daysAgo: 90), now: now))
        #expect(!month.removesAudio(of: call(.transcribing, daysAgo: 90), now: now))
        var queued = call(.stopped, daysAgo: 90)
        queued.pendingJob = TranscriptionJob(recording: UUID(), model: "m", diarize: false)
        #expect(!month.removesAudio(of: queued, now: now))
        var removed = call(.done, daysAgo: 90)
        removed.audioRemovedAt = now
        #expect(!month.removesAudio(of: removed, now: now))
        #expect(!profile.removesAudio(of: .file(FileReference(path: "/a.m4a")), now: now))
    }

    @Test func callSettingsAreKeptInVoiceJSON() throws {
        let old = Data(#"{"schemaVersion":1,"isEnabled":true}"#.utf8)
        let defaults = try JSONDecoder().decode(VoiceSettings.self, from: old)
        #expect(defaults.callAudioRetention == .always)
        #expect(defaults.callDiarize)
        #expect(!defaults.callConsentShown)
        var settings = VoiceSettings()
        settings.callAudioRetention = .untilTranscribed
        settings.callDiarize = false
        settings.callConsentShown = true
        let back = try JSONDecoder().decode(VoiceSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.callAudioRetention == .untilTranscribed)
        #expect(!back.callDiarize)
        #expect(back.callConsentShown)
        // A term this version does not know stays in the file.
        let newer = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"callAudioRetention":"week"}"#.utf8))
        #expect(newer.callAudioRetention == .always)
        #expect(newer.unreadableKeys == ["callAudioRetention"])
        // The values match meta.json's.
        #expect(CallAudioRetention.allCases.map(\.rawValue) == RecordingMeta.AudioRetention.allCases.map(\.rawValue))
    }

    @Test func profileKeysOfCalls() {
        let forced: [String: Any] = [ManagedSettings.Key.callRecordingDisabled: true,
                                     ManagedSettings.Key.callAudioKeepDisabled: true]
        let managed = ManagedSettings { forced[$0] }
        #expect(managed.callRecordingDisabled)
        #expect(managed.callAudioKeepDisabled)
        #expect(managed.forcesAnyKey)
        #expect(!ManagedSettings { _ in nil }.callRecordingDisabled)
    }
}
