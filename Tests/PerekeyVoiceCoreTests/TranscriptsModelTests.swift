// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyVoiceCore
import Testing

struct TranscriptsModelTests {
    static let file = RecordingMeta.file(FileReference(path: "/Users/anna/Movies/интервью.mp4"))

    static func call(state: RecordingMeta.State = .done, audioRemoved: Bool = false, segments: Bool = true) -> RecordingMeta {
        var meta = RecordingMeta.call(source: .app(bundleID: "us.zoom.xos", name: "zoom.us"), startHostTime: 1,
                                      audioRetention: .month)
        meta.state = state
        if segments {
            meta.segments = [RecordingMeta.Segment(track: .mic, file: "mic-0001.aac", startHostTime: 1, startOffset: 0,
                                                   frames: 16_000, closed: true)]
        }
        if audioRemoved { meta.audioRemovedAt = Date() }
        return meta
    }

    // MARK: Status

    @Test func queueStatesShowAsTheyAre() {
        let meta = Self.file
        func status(_ phase: TranscriptionPhase?, transcript: Bool = false) -> RecordingStatus {
            RecordingStatus.of(meta: meta, hasTranscript: transcript, phase: phase)
        }
        #expect(status(.queued) == .queued)
        #expect(status(.preparingModel) == .preparingModel)
        #expect(status(.transcribing(0.34)) == .transcribing(0.34))
        #expect(status(.waitingForDictation(0.5)) == .waitingForDictation(0.5))
        #expect(status(.diarizing(0.9)) == .diarizing(0.9))
        #expect(status(.failed(.unreadable)) == .failed(.unreadable))
        #expect(status(.done, transcript: true) == .done)
        #expect(status(nil, transcript: true) == .done)
        #expect(status(.cancelled) == .untranscribed)
        #expect(status(nil) == .untranscribed)
    }

    @Test func pendingPhaseWinsOverTheOldTranscript() {
        let status = RecordingStatus.of(meta: Self.file, hasTranscript: true, phase: .transcribing(0.1))
        #expect(status == .transcribing(0.1))
        #expect(status.isPending)
        #expect(status.progress == 0.1)
        #expect(RecordingStatus.done.progress == nil)
        #expect(RecordingStatus.transcribing(1.7).progress == 1)
    }

    @Test func aCutOffRecordingIsInterruptedUnlessItRunsNow() {
        let meta = Self.call(state: .recording)
        #expect(RecordingStatus.of(meta: meta, hasTranscript: false, phase: nil) == .interrupted)
        #expect(RecordingStatus.of(meta: meta, hasTranscript: false, phase: nil, isLive: true) == .recording)
        // Queued by «Расшифровать»: the queue's phase takes over.
        #expect(RecordingStatus.of(meta: meta, hasTranscript: false, phase: .queued) == .queued)
    }

    @Test func aJobLeftInMetaIsQueuedAtLaunch() {
        var meta = Self.file
        meta.pendingJob = TranscriptionJob(recording: UUID(), model: "parakeet-tdt-v3", diarize: false)
        #expect(RecordingStatus.of(meta: meta, hasTranscript: false, phase: nil) == .queued)
        #expect(RecordingStatus.of(meta: meta, hasTranscript: false, phase: .cancelled) == .untranscribed)
    }

    // MARK: Buttons

    @Test func retranscribeIsHiddenWithoutAudio() {
        let kept = RecordingCapabilities(meta: Self.call(), hasTranscript: true, status: .done)
        #expect(kept.hasAudio && kept.canRetranscribe && kept.canPlay && kept.canExport)

        let removed = RecordingCapabilities(meta: Self.call(audioRemoved: true), hasTranscript: true, status: .done)
        #expect(!removed.hasAudio && !removed.canRetranscribe && !removed.canPlay)
        #expect(removed.canExport && removed.canRenameSpeakers)

        let empty = RecordingCapabilities(meta: Self.call(segments: false), hasTranscript: true, status: .done)
        #expect(!empty.hasAudio && !empty.canRetranscribe)
    }

    @Test func aFileKeepsItsSourceAndNeverLosesAudio() {
        var meta = Self.file
        meta.audioRemovedAt = Date()
        // The term is for calls: a file's audio is the user's.
        #expect(RecordingCapabilities(meta: meta, hasTranscript: true, status: .done).canRetranscribe)
    }

    @Test func nothingToRetranscribeWhileItRuns() {
        let busy = RecordingCapabilities(meta: Self.file, hasTranscript: true, status: .transcribing(0.2))
        #expect(!busy.canRetranscribe && !busy.canResume)
        let live = RecordingCapabilities(meta: Self.call(state: .recording), hasTranscript: false, status: .recording)
        #expect(!live.canResume)
    }

    @Test func resumeIsOfferedForACutOffRecordingWithAudio() {
        let cut = RecordingCapabilities(meta: Self.call(state: .recording), hasTranscript: false, status: .interrupted)
        #expect(cut.canResume && !cut.canExport && !cut.canPlay)
        let nothing = RecordingCapabilities(meta: Self.call(state: .recording, segments: false), hasTranscript: false,
                                            status: .interrupted)
        #expect(!nothing.canResume)
        let failed = RecordingCapabilities(meta: Self.file, hasTranscript: false, status: .failed(.engineFailed))
        #expect(failed.canResume)
    }

    // MARK: Title

    @Test func titlesComeFromTheSource() {
        #expect(RecordingTitle(Self.file) == .file("интервью.mp4"))
        #expect(RecordingTitle(Self.call()) == .app("zoom.us"))
        var system = Self.call()
        system.source = .system
        #expect(RecordingTitle(system) == .system)
        var nameless = Self.call()
        nameless.source = RecordingMeta.Source(kind: .app)
        #expect(RecordingTitle(nameless) == .call)
    }

    // MARK: Search

    static let segments = [
        TimedSegment(start: 0, end: 1, text: "Ёлка стоит у окна, ёлка большая"),
        TimedSegment(start: 1, end: 2, text: "Ничего"),
        TimedSegment(start: 2, end: 3, text: "ЕЛКА снова"),
    ]

    @Test func searchIgnoresCaseAndDiacritics() {
        var search = TranscriptSearch()
        search.update(query: "елка", in: Self.segments)
        #expect(search.matches.map(\.segment) == [0, 0, 2])
        #expect(search.matches[0] == .init(segment: 0, lower: 0, upper: 4))
        #expect(search.matches[1].lower == 19)
        #expect(search.current == 0)
        #expect(search.matches(inSegment: 0).count == 2)
        #expect(search.matches(inSegment: 1).isEmpty)
    }

    @Test func arrowsWrapAround() {
        var search = TranscriptSearch()
        search.update(query: "елка", in: Self.segments)
        search.next(); search.next()
        #expect(search.current == 2)
        search.next()
        #expect(search.current == 0)
        search.previous()
        #expect(search.current == 2)
        #expect(search.currentMatch?.segment == 2)
    }

    @Test func emptyOrMissingQueryHasNoMatches() {
        var search = TranscriptSearch()
        search.update(query: "   ", in: Self.segments)
        #expect(search.matches.isEmpty && search.current == nil)
        search.update(query: "нет такого", in: Self.segments)
        #expect(search.matches.isEmpty && search.current == nil)
        search.next(); search.previous()
        #expect(search.current == nil)
        #expect(search.currentMatch == nil)
    }

    @Test func theCurrentMatchSurvivesAnUpdateOfTheSameQuery() {
        var search = TranscriptSearch()
        search.update(query: "елка", in: Self.segments)
        search.next()
        search.update(query: "елка", in: Self.segments)
        #expect(search.current == 1)
    }

    @Test func offsetsCountCharactersNotUTF16() {
        var search = TranscriptSearch()
        let segment = TimedSegment(start: 0, end: 1, text: "👨‍👩‍👧 привет 🎄 привет")
        search.update(query: "привет", in: [segment])
        #expect(search.matches.map(\.lower) == [2, 11])
        let text = segment.text
        let first = search.matches[0]
        let start = text.index(text.startIndex, offsetBy: first.lower)
        let end = text.index(text.startIndex, offsetBy: first.upper)
        #expect(text[start..<end] == "привет")
    }

    // MARK: Settings

    @Test func aProfileForcesAudioToGoAndBackupToStay() {
        let settings = VoiceSettings(callAudioRetention: .always, includesRecordingsInBackup: true)
        let free = ManagedSettings()
        #expect(settings.effectiveCallAudioRetention(managed: free) == .always)
        #expect(settings.includesRecordingsInBackup(managed: free))
        let managed = ManagedSettings(callAudioKeepDisabled: true, transcriptsBackupDisabled: true)
        #expect(settings.effectiveCallAudioRetention(managed: managed) == .untilTranscribed)
        #expect(!settings.includesRecordingsInBackup(managed: managed))
        #expect(managed.forcesAnyKey)
    }

    @Test func managedKeysAreReadFromTheProfile() {
        let managed = ManagedSettings(forced: { key in
            [ManagedSettings.Key.callAudioKeepDisabled: true, ManagedSettings.Key.transcriptsBackupDisabled: true][key]
        })
        #expect(managed.callAudioKeepDisabled && managed.transcriptsBackupDisabled)
        #expect(!ManagedSettings(forced: { _ in nil }).callAudioKeepDisabled)
    }

    @Test func retentionMapsToTheMetaTerms() {
        for choice in CallAudioRetention.allCases {
            #expect(RecordingMeta.AudioRetention(choice).rawValue == choice.rawValue)
        }
    }

    @Test func settingsKeepTheRecordingChoicesOnDisk() throws {
        let settings = VoiceSettings(callAudioRetention: .untilTranscribed, includesRecordingsInBackup: true)
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(VoiceSettings.self, from: data)
        #expect(back.callAudioRetention == .untilTranscribed)
        #expect(back.includesRecordingsInBackup)
        let defaults = try JSONDecoder().decode(VoiceSettings.self, from: Data("{}".utf8))
        #expect(defaults.callAudioRetention == .month)
        #expect(!defaults.includesRecordingsInBackup)
        // A value this version cannot read falls back, and the file keeps it.
        let odd = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"callAudioRetention":"forever"}"#.utf8))
        #expect(odd.callAudioRetention == .month)
        #expect(odd.unreadableKeys.contains("callAudioRetention"))
    }

    // MARK: Disk

    @Test func diskUsageSumsTheFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "perekey-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RecordingsDiskUsage.bytes(in: root) == 0)
        let folder = RecordingsFolder(root: root)
        let id = try folder.create(Self.file, excludedFromBackup: true)
        try Data(count: 50_000).write(to: folder.directory(for: id).appending(path: "mic-0001.aac"))
        #expect(RecordingsDiskUsage.bytes(in: root) >= 50_000)
    }
}
