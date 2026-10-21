// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AVFoundation
import Observation
import PerekeyVoiceCore

/// Plays a phrase of a recording from its start: a click on the phrase in the
/// «Расшифровки» window. A call's tracks are ADTS segments, read as
/// `AVAudioFile` and started at the frame `locate` gives, priming included.
/// A file is read from where its bookmark points.
@MainActor
@Observable
final class TranscriptPlayer {
    enum Failure: Error, Equatable {
        /// The call's audio is gone, or there is none.
        case noAudio
        /// The chosen file moved, was deleted, or cannot be opened; the name for the message.
        case sourceUnavailable(String)
        /// The recording has no sound at that second: a gap, or past the end.
        case nothingHere
    }

    /// Where playback is on the recording's scale, about; nil when it is silent.
    private(set) var playingSecond: Double?
    /// The speaker whose phrase plays, nil for a file's or an unknown speaker's.
    private(set) var playingTrack: RecordingTrack?
    var isPlaying: Bool { playingSecond != nil }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var nodes: [AVAudioPlayerNode] = []
    @ObservationIgnored private var scoped: URL?
    @ObservationIgnored private var completion = PlaybackCompletion()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// Plays `seconds` of the recording on. `speaker` picks a call's track:
    /// «Я» is the microphone, anyone else the system audio; without a speaker both play.
    func play(_ item: RecordingItem, in folder: RecordingsFolder, from seconds: Double, speaker: TranscriptSpeaker.Kind?) throws {
        stop()
        let plan = try Self.plan(item, in: folder, from: seconds, speaker: speaker)
        let engine = AVAudioEngine()
        var nodes: [AVAudioPlayerNode] = []
        completion.begin(parts: plan.parts.count)
        let mine = completion.generation
        for part in plan.parts {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: part.file.processingFormat)
            node.scheduleSegment(part.file, startingFrame: part.startFrame, frameCount: part.frames, at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.finished(mine) }
            }
            nodes.append(node)
        }
        do {
            try engine.start()
        } catch {
            plan.release()
            throw Failure.noAudio
        }
        nodes.forEach { $0.play() }
        self.engine = engine
        self.nodes = nodes
        scoped = plan.scoped
        playingTrack = plan.track
        let started = Date()
        playingSecond = seconds
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, completion.generation == mine, playingSecond != nil else { return }
                playingSecond = seconds + Date().timeIntervalSince(started)
            }
        }
    }

    func stop() {
        completion.invalidate()
        ticker?.cancel()
        ticker = nil
        nodes.forEach { $0.stop() }
        engine?.stop()
        nodes = []
        engine = nil
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        playingSecond = nil
        playingTrack = nil
    }

    private func finished(_ mine: Int) {
        // The last buffer to end ends the playback: both tracks of a call are one.
        if completion.finish(generation: mine) { stop() }
    }

    // MARK: The files to read

    private struct Part {
        var file: AVAudioFile
        var startFrame: AVAudioFramePosition
        var frames: AVAudioFrameCount
    }

    private struct Plan {
        var parts: [Part]
        var track: RecordingTrack?
        var scoped: URL?

        func release() { scoped?.stopAccessingSecurityScopedResource() }
    }

    private static func plan(_ item: RecordingItem, in folder: RecordingsFolder, from seconds: Double,
                             speaker: TranscriptSpeaker.Kind?) throws -> Plan
    {
        let meta = item.meta
        switch meta.kind {
        case .file:
            guard let reference = meta.source.file else { throw Failure.noAudio }
            let (url, scoped) = try resolve(reference)
            do {
                let file = try AVAudioFile(forReading: url)
                let start = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
                guard start >= 0, start < file.length else { throw Failure.nothingHere }
                return Plan(parts: [Part(file: file, startFrame: start, frames: AVAudioFrameCount(file.length - start))],
                            track: nil, scoped: scoped)
            } catch let failure as Failure {
                scoped?.stopAccessingSecurityScopedResource()
                throw failure
            } catch {
                scoped?.stopAccessingSecurityScopedResource()
                throw Failure.sourceUnavailable(url.lastPathComponent)
            }
        case .call:
            guard meta.audioRemovedAt == nil else { throw Failure.noAudio }
            let wanted: [RecordingTrack] = switch speaker {
            case .me?: [.mic]
            case .others?, .speaker?: [.sys]
            case nil: RecordingTrack.allCases
            }
            let directory = folder.directory(for: item.id)
            var parts: [Part] = []
            for track in wanted where meta.tracks.contains(track) {
                guard case let .track(_, segments)? = meta.audio(of: track, in: directory),
                      let position = segments.locate(seconds, sampleRate: meta.sampleRate),
                      let file = try? AVAudioFile(forReading: URL(fileURLWithPath: segments[position.segment].path))
                else { continue }
                var end = file.length
                if let written = segments[position.segment].frames {
                    end = min(end, RecordingMeta.adtsPrimingFrames + written)
                }
                guard position.frame < end else { continue }
                parts.append(Part(file: file, startFrame: position.frame, frames: AVAudioFrameCount(end - position.frame)))
            }
            guard !parts.isEmpty else { throw Failure.nothingHere }
            return Plan(parts: parts, track: wanted.count == 1 ? wanted[0] : nil, scoped: nil)
        }
    }

    /// The file a bookmark points to now, or where it was; access opened for a sandbox.
    private static func resolve(_ reference: FileReference) throws -> (URL, URL?) {
        let name = URL(fileURLWithPath: reference.path).lastPathComponent
        var url: URL?
        if let data = reference.bookmark {
            var stale = false
            url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let target = url ?? URL(fileURLWithPath: reference.path)
        let opened = target.startAccessingSecurityScopedResource()
        guard FileManager.default.isReadableFile(atPath: target.path) else {
            if opened { target.stopAccessingSecurityScopedResource() }
            throw Failure.sourceUnavailable(name)
        }
        return (target, opened ? target : nil)
    }
}
#endif
