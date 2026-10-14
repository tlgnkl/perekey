// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AVFoundation
import CoreAudio
import Foundation
import os
import PerekeyVoiceCore

/// What happens to call recordings outside a recording: the one a crash
/// cut off, and the audio past its term.
public enum CallRecordings {
    private static let log = Logger(subsystem: "app.perekey", category: "call-recorder")

    /// At launch: a call found `recording` was cut off by a crash or a power
    /// loss. It turns `stopped`, with the segment that was open left open
    /// (read to its end) and its length taken from the file, and comes back
    /// for Perekey to offer its transcription. Returns their ids, oldest first.
    @discardableResult
    public static func recoverInterrupted(in folder: RecordingsFolder, except active: UUID? = nil) -> [UUID] {
        var found: [(UUID, Date)] = []
        for id in folder.recordings() where id != active {
            guard case let .loaded(meta) = folder.meta(id), meta.kind == .call, meta.state == .recording else {
                continue
            }
            let directory = folder.directory(for: id)
            do {
                try folder.updateMeta(id) { meta in
                    var end = 0.0
                    meta.segments.removeAll { segment in
                        guard !segment.closed else { return false }
                        // A segment opened right before the crash may have no packet.
                        let url = directory.appending(path: segment.file, directoryHint: .notDirectory)
                        guard let frames = readableFrames(url), frames > 0 else {
                            try? FileManager.default.removeItem(at: url)
                            return true
                        }
                        end = max(end, segment.startOffset + Double(frames) / meta.sampleRate)
                        return false
                    }
                    for segment in meta.segments where segment.closed {
                        end = max(end, segment.startOffset + Double(segment.frames) / meta.sampleRate)
                    }
                    meta.state = .stopped
                    meta.duration = end
                }
                // Cut off before its first block: nothing to offer.
                if case let .loaded(meta) = folder.meta(id), meta.segments.isEmpty {
                    try? folder.remove(id)
                    continue
                }
                found.append((id, meta.createdAt))
            } catch {
                log.error("recovery of a recording failed: \(CallRecorder.describe(error), privacy: .public)")
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Samples in an ADTS segment past the priming: a file cut by a crash
    /// reads to its last whole packet. Nil when it does not open.
    static func readableFrames(_ url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return max(0, file.length - RecordingMeta.adtsPrimingFrames)
    }

    /// Removes the audio past its term (`CallAudioPolicy`): the segments
    /// go, the transcript and `meta.json` stay with `audioRemovedAt`.
    /// Returns the recordings it cleaned.
    @discardableResult
    public static func removeExpiredAudio(in folder: RecordingsFolder, policy: CallAudioPolicy, now: Date = Date(),
                                          except active: UUID? = nil) -> [UUID]
    {
        var cleaned: [UUID] = []
        for id in folder.recordings() where id != active {
            guard case let .loaded(meta) = folder.meta(id), policy.removesAudio(of: meta, now: now) else { continue }
            do {
                try folder.updateMeta(id) { meta in
                    // Read again under the lock: the queue may have taken it meanwhile.
                    guard policy.removesAudio(of: meta, now: now) else { return }
                    let directory = folder.directory(for: id)
                    for segment in meta.segments {
                        try? FileManager.default.removeItem(at: directory.appending(path: segment.file,
                                                                                    directoryHint: .notDirectory))
                    }
                    meta.audioRemovedAt = now
                }
                cleaned.append(id)
            } catch {
                log.error("removing a call's audio failed: \(CallRecorder.describe(error), privacy: .public)")
            }
        }
        return cleaned
    }

    /// Bytes free for the recordings, as Finder counts them (purgeable
    /// space included). Nil when the volume does not say.
    @Sendable
    public static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// A program a call can be recorded from.
public struct CallSourceApp: Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    /// It plays sound now.
    public let isPlaying: Bool

    public var id: String { bundleID }
}

extension CallSourceApp {
    /// The programs Core Audio knows: ones that used sound since they
    /// started, by the app a helper plays for; playing ones first. Perekey
    /// itself is not among them.
    public static func running() -> [CallSourceApp] {
        let own = Bundle.main.bundleIdentifier
        var apps: [String: CallSourceApp] = [:]
        for process in AudioProcessList.all() {
            let owner = NSRunningApplication(processIdentifier: process.responsiblePID)
                ?? NSRunningApplication(processIdentifier: process.pid)
            guard let owner, owner.activationPolicy == .regular, let bundleID = owner.bundleIdentifier,
                  bundleID != own
            else { continue }
            let playing = process.isRunningOutput || apps[bundleID]?.isPlaying == true
            apps[bundleID] = CallSourceApp(bundleID: bundleID, name: owner.localizedName ?? bundleID,
                                           isPlaying: playing)
        }
        return apps.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// The default output device, for the panel's advice on headphones.
public enum AudioOutput {
    /// The Mac's own speakers play: the other side reaches the microphone
    /// too. False for headphones in the jack, Bluetooth, AirPlay, USB.
    public static var isBuiltInSpeakers: Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard let device: AudioDeviceID = MicrophoneList.value(system, kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown,
              let transport: UInt32 = MicrophoneList.value(device, kAudioDevicePropertyTransportType),
              transport == kAudioDeviceTransportTypeBuiltIn
        else { return false }
        // The jack and the speakers are one device: its data source tells them apart.
        guard let source: UInt32 = MicrophoneList.value(device, kAudioDevicePropertyDataSource,
                                                        scope: kAudioDevicePropertyScopeOutput)
        else { return true }
        return source == speakers
    }

    /// `'ispk'`: internal speakers.
    private static let speakers: UInt32 = 0x6973_706B
}
