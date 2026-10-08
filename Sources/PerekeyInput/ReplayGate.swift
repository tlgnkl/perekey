// SPDX-License-Identifier: GPL-3.0-or-later

/// Keeps replayed input ahead of the keys typed after it.
///
/// When the fence lets go, the held events are posted again, marked
/// `.replayed`, and come back through the tap a moment later. A key the user
/// presses meanwhile may already be queued before them: it would reach the
/// tap first and overtake them ("приветм ир"). So while replays are in
/// flight, user events wait here, unseen by the machine. Once the last replay
/// came back they are posted as the next replayed batch, and the machine
/// sees them in order when they come back.
///
/// Pure bookkeeping, generic over the event, so it is tested without
/// `CGEvent`s. Used on the tap thread only.
struct ReplayGate<Event> {
    /// Seconds to wait for replays that do not come back (another tap ate
    /// them, the tap was off) before the waiting events go out anyway.
    static var timeout: Double { 0.5 }

    /// Replayed events posted that have not come back yet.
    private(set) var inFlight = 0
    /// User events that came while replays were in flight, oldest first.
    private(set) var waiting: [Event] = []
    /// When the last batch was posted.
    private(set) var postedAt = 0.0

    /// When to give up on replays in flight, while something waits for them.
    var deadline: Double? { waiting.isEmpty ? nil : postedAt + Self.timeout }

    /// `count` replayed events were posted at `time`.
    mutating func posted(_ count: Int, at time: Double) {
        guard count > 0 else { return }
        inFlight += count
        postedAt = time
    }

    /// A user event reached the tap at `time`. True when it must wait: keep
    /// a copy with `hold(_:)` and swallow the original. Replays older than
    /// `timeout` with nothing waiting are given up on here.
    mutating func mustWait(at time: Double) -> Bool {
        guard inFlight > 0 else { return false }
        if waiting.isEmpty, time >= postedAt + Self.timeout {
            inFlight = 0
            return false
        }
        return true
    }

    mutating func hold(_ event: Event) {
        waiting.append(event)
    }

    /// A replayed event came back.
    mutating func replayedSeen() {
        if inFlight > 0 { inFlight -= 1 }
    }

    /// The waiting events, once no replay is in flight: post them as replayed
    /// and report them with `posted(_:at:)`.
    mutating func takeReady() -> [Event] {
        guard inFlight == 0, !waiting.isEmpty else { return [] }
        defer { waiting.removeAll() }
        return waiting
    }

    /// At `time`, past `deadline`: forget the replays in flight and hand out
    /// the waiting events, to post without counting. Nil before the deadline.
    mutating func expire(at time: Double) -> [Event]? {
        guard let deadline, time >= deadline else { return nil }
        inFlight = 0
        defer { waiting.removeAll() }
        return waiting
    }

    /// Events may have been lost: start over. Returns the waiting events, to
    /// post after whatever the machine releases.
    mutating func reset() -> [Event] {
        inFlight = 0
        defer { waiting.removeAll() }
        return waiting
    }
}
