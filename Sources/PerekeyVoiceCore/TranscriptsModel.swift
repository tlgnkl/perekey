// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// What a row of the «Расшифровки» list says about a recording.
public enum RecordingStatus: Sendable, Equatable {
    /// A call being recorded right now.
    case recording
    case queued
    case preparingModel
    /// Share of the work done, 0…1.
    case transcribing(Double)
    case waitingForDictation(Double)
    case diarizing(Double)
    case done
    case failed(TranscriptionFailure)
    /// `meta.json` says `recording` and no recorder runs: a crash cut it off.
    /// The audio written so far can still be transcribed.
    case interrupted
    /// Nothing queued and no transcript: the user cancelled it.
    case untranscribed

    /// In the queue or running.
    public var isPending: Bool {
        switch self {
        case .queued, .preparingModel, .transcribing, .waitingForDictation, .diarizing: true
        default: false
        }
    }

    /// The share of the work done, for the pending states that know it.
    public var progress: Double? {
        switch self {
        case let .transcribing(share), let .waitingForDictation(share), let .diarizing(share): min(1, max(0, share))
        default: nil
        }
    }

    /// The status of a recording from what the disk and the queue say.
    /// A pending queue phase wins over an old transcript: it is being replaced.
    public static func of(meta: RecordingMeta, hasTranscript: Bool, phase: TranscriptionPhase?,
                          isLive: Bool = false) -> RecordingStatus
    {
        if isLive { return .recording }
        switch phase {
        case .queued: return .queued
        case .preparingModel: return .preparingModel
        case let .transcribing(share): return .transcribing(share)
        case let .waitingForDictation(share): return .waitingForDictation(share)
        case let .diarizing(share): return .diarizing(share)
        case let .failed(failure): return .failed(failure)
        case .done, .cancelled, nil: break
        }
        if meta.state == .recording { return .interrupted }
        // The queue was cut off with a job in `meta.json`: it starts again at launch.
        if meta.pendingJob != nil, phase != .cancelled { return .queued }
        if hasTranscript { return .done }
        return .untranscribed
    }
}

/// What the buttons of a recording may do.
public struct RecordingCapabilities: Sendable, Equatable {
    /// There is audio on disk, or a file to read: a call's audio is gone
    /// once its term ran out (`audioRemovedAt`).
    public var hasAudio: Bool
    /// «Расшифровать заново» with another model.
    public var canRetranscribe: Bool
    /// «Расшифровать» on a recording the crash cut off.
    public var canResume: Bool
    /// A click on a phrase plays it.
    public var canPlay: Bool
    public var canExport: Bool
    public var canRenameSpeakers: Bool

    public init(meta: RecordingMeta, hasTranscript: Bool, status: RecordingStatus) {
        switch meta.kind {
        case .file: hasAudio = meta.source.file != nil
        case .call: hasAudio = meta.audioRemovedAt == nil && !meta.segments.isEmpty
        }
        let idle = !status.isPending && status != .recording
        canRetranscribe = hasAudio && idle && hasTranscript
        canResume = hasAudio && (status == .interrupted || status == .untranscribed || isFailure(status)) && !hasTranscript
        canPlay = hasAudio && hasTranscript
        canExport = hasTranscript
        canRenameSpeakers = hasTranscript
    }
}

private func isFailure(_ status: RecordingStatus) -> Bool {
    if case .failed = status { true } else { false }
}

/// What to call a recording; the window turns it into words in its language.
public enum RecordingTitle: Sendable, Equatable {
    /// The file's name.
    case file(String)
    /// A call of one program.
    case app(String)
    /// A call of all system audio.
    case system
    /// A call from an app Perekey cannot name.
    case call

    public init(_ meta: RecordingMeta) {
        switch meta.source.kind {
        case .file:
            let name = meta.source.file.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? ""
            self = name.isEmpty ? .call : .file(name)
        case .app:
            self = meta.source.name.flatMap { $0.isEmpty ? nil : .app($0) } ?? .call
        case .system:
            self = .system
        }
    }
}

extension RecordingMeta.AudioRetention {
    public init(_ choice: CallAudioRetention) {
        switch choice {
        case .always: self = .always
        case .month: self = .month
        case .untilTranscribed: self = .untilTranscribed
        }
    }
}

extension VoiceSettings {
    /// The term for a new call's audio: the user's choice, unless a profile
    /// says audio is never kept.
    public func effectiveCallAudioRetention(managed: ManagedSettings) -> CallAudioRetention {
        managed.callAudioKeepDisabled ? .untilTranscribed : callAudioRetention
    }

    /// Whether recordings are in Time Machine: only when the user said so and
    /// no profile forbids it.
    public func includesRecordingsInBackup(managed: ManagedSettings) -> Bool {
        includesRecordingsInBackup && !managed.transcriptsBackupDisabled
    }
}

// MARK: - Search

/// The search box of the transcript: where the query is found, and which
/// match is the current one (↑ ↓).
public struct TranscriptSearch: Sendable, Equatable {
    /// A hit in one phrase; offsets count characters of the phrase's text.
    public struct Match: Sendable, Equatable {
        public var segment: Int
        public var lower: Int
        public var upper: Int
    }

    public private(set) var query = ""
    public private(set) var matches: [Match] = []
    /// Index in `matches`; nil without matches.
    public private(set) var current: Int?

    public init() {}

    public var currentMatch: Match? { current.map { matches[$0] } }

    /// Finds `query` in the phrases, without regard to case or diacritics
    /// («Ёлка» is found by «елка»). Keeps the current match when it is
    /// still there, so that a transcript changing under the search does not
    /// jump back to the first hit.
    public mutating func update(query: String, in segments: [TimedSegment]) {
        let previous = currentMatch
        self.query = query
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = []
        current = nil
        guard !needle.isEmpty else { return }
        for (index, segment) in segments.enumerated() {
            var from = segment.text.startIndex
            while from < segment.text.endIndex,
                  let range = segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                                 range: from..<segment.text.endIndex)
            {
                let lower = segment.text.distance(from: segment.text.startIndex, to: range.lowerBound)
                let upper = segment.text.distance(from: segment.text.startIndex, to: range.upperBound)
                matches.append(Match(segment: index, lower: lower, upper: max(upper, lower + 1)))
                from = range.upperBound > range.lowerBound ? range.upperBound : segment.text.index(after: range.upperBound)
            }
        }
        current = matches.isEmpty ? nil : (previous.flatMap { matches.firstIndex(of: $0) } ?? 0)
    }

    /// ↓: the next match, from the last back to the first.
    public mutating func next() {
        guard let current else { return }
        self.current = (current + 1) % matches.count
    }

    /// ↑: the previous match, from the first round to the last.
    public mutating func previous() {
        guard let current else { return }
        self.current = (current - 1 + matches.count) % matches.count
    }

    /// The matches of one phrase, for highlighting.
    public func matches(inSegment index: Int) -> [Match] { matches.filter { $0.segment == index } }
}

// MARK: - Disk

/// How much room recordings take: the sum of their files.
public enum RecordingsDiskUsage {
    public static func bytes(in root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
