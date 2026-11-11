// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import PerekeyCore

/// The typing recording as the engine runs it on the tap thread: the buffer
/// (`RecordingBuffer`), its hand-over to the recorder (`SessionRecorder`), the
/// recorder's answers and the status the badge shows. The engine owns one
/// while the recording is on; its timer calls `tick()` once a second.
///
/// Apart from the engine so that the glue can be tested without a tap: the
/// tests give it a `hop` that runs the answers when they choose.
///
/// Used on one thread only, the tap thread (in tests, the test's). The
/// recorder's answers come from its queue and hop back through `hop`, which
/// runs them on that thread with the pipeline the engine holds then; an answer
/// for an earlier recording is told apart by `number` and dropped.
final class RecordingPipeline {
    typealias Hop = @Sendable (_ block: @escaping @Sendable (RecordingPipeline?) -> Void) -> Void

    let number: Int
    private(set) var buffer: RecordingBuffer
    private let recorder: SessionRecorder
    private let hop: Hop
    private let report: (TypingRecordingStatus) -> Void
    private var reported: TypingRecordingStatus?

    /// - Parameters:
    ///   - number: tells this recording from an earlier one when answers come.
    ///   - hop: runs a block on the thread the pipeline is used on, with the
    ///     pipeline that is current there (nil when none).
    ///   - report: the status changed; the engine tells the main thread.
    init(recorder: SessionRecorder, excludedApps: Set<String>, number: Int,
         options: RecordingBuffer.Options = RecordingBuffer.Options(),
         hop: @escaping Hop, report: @escaping (TypingRecordingStatus) -> Void)
    {
        self.recorder = recorder
        self.number = number
        self.hop = hop
        self.report = report
        buffer = RecordingBuffer(options: options, excludedApps: excludedApps)
        publish()
    }

    var excludedApps: Set<String> {
        get { buffer.excludedApps }
        set { buffer.excludedApps = newValue }
    }

    var status: TypingRecordingStatus { buffer.status }

    /// What the machine just did. `quiet` and `snapshot` as `RecordingBuffer.record`.
    func record(_ event: InputEvent, _ output: Output, quiet: () -> Bool,
                snapshot: () -> (MachineSnapshot, Classifier?))
    {
        if buffer.record(event, output, quiet: quiet, snapshot: snapshot) { handOver() }
        publish()
    }

    /// The engine's timer, once a second: what typing left in the array goes on.
    func tick() {
        if !buffer.entries.isEmpty { handOver() }
    }

    /// The recording stops: the rest is written and the file closed, on the
    /// recorder's queue.
    func stop() {
        recorder.write(buffer.takeAll(), close: true) { _ in }
    }

    /// The recording stops, and the call returns after the rest is written and
    /// the file closed. For the quit of the app: a queue that is still
    /// working when the process ends loses what it holds.
    func finish() {
        recorder.finish(buffer.takeAll())
    }

    /// The files were erased: starts over, the next segment starts a file.
    func restart() {
        buffer.restart()
        publish()
    }

    private func handOver() {
        let batch = buffer.take()
        // Empty: no array is spare. The entries wait; the buffer ends the
        // segment before they overflow.
        guard !batch.isEmpty else { return }
        let number = number
        recorder.write(batch) { [hop] written in
            hop { pipeline in
                guard let pipeline, pipeline.number == number else { return }
                pipeline.answered(written)
            }
        }
    }

    /// The recorder wrote a batch.
    func answered(_ written: SessionRecorder.Written) {
        buffer.written(written.batch, newDay: written.newDay, failed: written.failed)
        publish()
    }

    private func publish() {
        let status = buffer.status
        guard status != reported else { return }
        reported = status
        report(status)
    }
}
#endif
