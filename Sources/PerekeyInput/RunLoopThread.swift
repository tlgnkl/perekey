// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// A thread with its own `CFRunLoop`, for work that may block and so must stay
/// off the main thread and the tap thread. Run loop sources (an `AXObserver`)
/// can live on it. Blocks go in with `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`
/// (docs/PLAN.md "Потоки"): callers never wait.
final class RunLoopThread: Sendable {
    /// `CFRunLoop` is thread-safe for perform, wake up and stop.
    private struct LoopRef: @unchecked Sendable { let loop: CFRunLoop }

    private struct State: Sendable {
        var loop: LoopRef?
        /// Blocks sent before the thread published its run loop.
        var pending: [@Sendable () -> Void] = []
        var stopped = false
        var exited = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(name: String, qualityOfService: QualityOfService) {
        let thread = Thread { [state] in Self.run(state) }
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()
    }

    /// Runs `block` on the thread, in order. Dropped after `stop`.
    func perform(_ block: @escaping @Sendable () -> Void) {
        state.withLock { state in
            guard !state.stopped else { return }
            if let ref = state.loop {
                Self.schedule(block, on: ref.loop)
            } else {
                state.pending.append(block)
            }
        }
    }

    /// Runs `final` on the thread after the blocks already sent, then ends the
    /// thread. Does not wait. If the thread has not started its run loop yet,
    /// nothing ran there, and `final` is skipped.
    func stop(after final: @escaping @Sendable () -> Void = {}) {
        state.withLock { state in
            guard !state.stopped else { return }
            state.stopped = true
            state.pending.removeAll()
            if let ref = state.loop {
                Self.schedule({
                    final()
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }, on: ref.loop)
            }
        }
    }

    /// The thread has left its run loop. For tests.
    var hasExited: Bool { state.withLock { $0.exited } }

    private static func schedule(_ block: @escaping @Sendable () -> Void, on loop: CFRunLoop) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    private static func run(_ state: OSAllocatedUnfairLock<State>) {
        let loop: CFRunLoop = CFRunLoopGetCurrent()
        // `CFRunLoopRun` returns at once from a run loop without sources. This
        // one is never signalled: it costs nothing while idle.
        var context = CFRunLoopSourceContext()
        let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        CFRunLoopAddSource(loop, keepAlive, .defaultMode)

        let ref = LoopRef(loop: loop)
        let started = state.withLock { state -> Bool in
            guard !state.stopped else { return false }
            state.loop = ref
            // Inside the run loop, so a `stop` among them stops it.
            for block in state.pending { schedule(block, on: ref.loop) }
            state.pending.removeAll()
            return true
        }
        if started { CFRunLoopRun() }

        CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
        state.withLock { state in
            state.loop = nil
            state.stopped = true
            state.exited = true
        }
    }
}
