// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyVoiceCore

// Hidden checks of a call recording as the app makes it: `CallRecorder`
// with the microphone and the tap, into a recordings folder of the check's
// choosing. For `kill -9` in the middle, and the recovery at the next launch:
//
//     Perekey --voice-check call --root /tmp/rec --source system --seconds 600 --segment 60 &
//     sleep 150; kill -9 $!
//     Perekey --voice-check call-recover --root /tmp/rec
//
// From a shell without the permissions the tap gives zeros and the
// microphone does not start; `--mic off` records the system track alone.

extension VoiceCheck.Command {
    static let call: [Self] = [.callRecord, .callRecover]

    static let callRecord = Self(name: "call",
                                 summary: "records a call with CallRecorder into --root (for kill -9); --mic off without TCC",
                                 options: ["root", "source", "seconds", "segment", "mic"]) { options, report in
        await CallCheck(options: options, report: report).record()
    }

    static let callRecover = Self(name: "call-recover",
                                  summary: "closes the recordings a crash cut off in --root, as at launch, and lists them",
                                  options: ["root"]) { options, report in
        CallCheck(options: options, report: report).recover()
    }
}

private struct CallCheck {
    let options: VoiceCheckOptions
    let report: VoiceCheckReport

    var folder: RecordingsFolder {
        options.string("root").map {
            RecordingsFolder(root: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true))
        } ?? RecordingsFolder()
    }

    func record() async -> Int32 {
        let source: CallRecorder.Source = switch options.string("source") {
        case nil, "system": .system
        case let id?: .app(bundleID: id, name: id)
        }
        let seconds = options.double("seconds", default: 30)
        var configuration = CallRecorder.Configuration()
        configuration.segmentSeconds = options.double("segment", default: CallRecordingLimits.segmentSeconds)
        let mic: any MicSource = options.string("mic") == "off" ? SilentMic() : AudioCapture()
        let report = report
        let recorder = CallRecorder(folder: folder, mic: mic, makeTap: CallRecorder.systemTap,
                                    configuration: configuration, onStatus: { status in
                                        report.line("status: \(status.phase), system audio \(status.systemAudio), "
                                            + "device changes \(status.deviceChanges)")
                                    })
        let id: UUID
        do {
            id = try await recorder.start(.init(source: source, retention: .always, model: VoiceSettings.defaultModel,
                                                diarize: false))
        } catch {
            report.line("FAIL: did not start: \(error)")
            return 1
        }
        report.line("recording \(id.uuidString.lowercased()) in \(folder.directory(for: id).path), pid \(getpid())")
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(seconds) {
            try? await Task.sleep(for: .seconds(1))
            let meta = folder.meta(id)
            if case let .loaded(meta) = meta {
                let closed = meta.segments.filter(\.closed).count
                report.line(String(format: "%.0f s: %d segments, %d closed; levels mic %.2f sys %.2f",
                                   (ContinuousClock.now - started) / .seconds(1), meta.segments.count, closed,
                                   recorder.meters.mic, recorder.meters.sys))
            }
        }
        await recorder.stop()
        if case let .loaded(meta) = folder.meta(id) {
            report.line("stopped: state \(meta.state.rawValue), duration \(meta.duration ?? 0) s, "
                + "\(meta.segments.count) segments, gaps \(meta.gaps.map(\.reason.rawValue))")
        }
        return 0
    }

    func recover() -> Int32 {
        let folder = folder
        let found = CallRecordings.recoverInterrupted(in: folder)
        report.line("recovered \(found.count): \(found.map { $0.uuidString.lowercased() })")
        for id in found {
            guard case let .loaded(meta) = folder.meta(id) else { continue }
            report.line("\(id.uuidString.lowercased()): state \(meta.state.rawValue), duration "
                + String(format: "%.2f s", meta.duration ?? 0))
            for segment in meta.segments {
                let url = folder.directory(for: id).appending(path: segment.file)
                let readable = CallRecordings.readableFrames(url) ?? -1
                report.line("  \(segment.file) at \(String(format: "%.2f", segment.startOffset)) s, "
                    + (segment.closed ? "closed, \(segment.frames) frames" : "open after the crash")
                    + ", readable \(readable) frames")
            }
        }
        report.line("Time Machine: Recordings/ excluded \(folder.isExcludedFromBackup)")
        return 0
    }
}

/// No microphone: a shell without the permission records the system track only.
private final class SilentMic: MicSource {
    func subscribe(_: any AudioSink) async throws -> AudioSubscription { AudioSubscription(id: 0) }
    func unsubscribe(_: AudioSubscription) async {}
    func hold() async {}
    func release() async {}
}
