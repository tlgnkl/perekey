// SPDX-License-Identifier: GPL-3.0-or-later

@testable import PerekeyCore

/// A text field as the app behind it handles posted keys: in the order they
/// were posted, a few milliseconds apart, the caret at the end of the text.
/// A key posted later never overtakes one posted earlier, so a Backspace the
/// app is late with lands before any text typed back after it.
final class AppField {
    enum Key: Equatable {
        case backspace
        case text(String)
    }

    var text: String
    var clock: Double
    /// Seconds between two keys the app handles.
    var step = 0.002
    /// Seconds one read of the field takes.
    var readTime = 0.0
    /// Text `Erasure.confirm` typed back, in order.
    private(set) var typedBack: [String] = []
    /// Keys posted and not handled yet, each with the earliest time it may be.
    private var queue: [(key: Key, at: Double)] = []
    /// What the app does by itself, at a given time.
    private var changes: [(at: Double, change: (inout String) -> Void)] = []

    init(_ text: String, clock: Double = 0) {
        self.text = text
        self.clock = clock
    }

    /// The snapshot the caret check would take with `word` before the caret.
    func snapshot(word: String) -> Erasure.Snapshot {
        let start = text.utf16.count - word.utf16.count
        return Erasure.Snapshot(start: start, lead: Self.slice(text, max(0, start - Erasure.Snapshot.leadLength)..<start),
                                word: word)
    }

    /// Posts `key`; the app handles it `delay` seconds later than it would.
    func post(_ key: Key, delay: Double = 0) {
        let after = max(clock, queue.last?.at ?? clock)
        queue.append((key, after + step + delay))
    }

    /// Posts `count` Backspaces. `eaten`: these (0-based) never reach the
    /// field. `late`: these come this many seconds late, and the ones after
    /// them wait behind them.
    func postBackspaces(_ count: Int, eaten: Set<Int> = [], late: [Int: Double] = [:]) {
        for index in 0..<count where !eaten.contains(index) {
            post(.backspace, delay: late[index] ?? 0)
        }
    }

    /// The app changes the text by itself at `time`.
    func schedule(at time: Double, _ change: @escaping (inout String) -> Void) {
        changes.append((time, change))
    }

    /// Time passes: the app handles what is due.
    func advance(by seconds: Double) {
        clock += seconds
        handleDue()
    }

    /// The app handles every key still posted and every change still to come,
    /// however late: what the field holds once all is over.
    func drain() {
        clock = ([clock] + queue.map(\.at) + changes.map(\.at)).max() ?? clock
        handleDue()
    }

    private func handleDue() {
        while true {
            let key = queue.first.flatMap { $0.at <= clock ? $0 : nil }
            let change = changes.indices.filter { changes[$0].at <= clock }.min { changes[$0].at < changes[$1].at }
            if let key, change.map({ key.at <= changes[$0].at }) ?? true {
                queue.removeFirst()
                switch key.key {
                case .backspace: if !text.isEmpty { text.removeLast() }
                case let .text(typed): text += typed
                }
            } else if let change {
                changes.remove(at: change).change(&text)
            } else {
                return
            }
        }
    }

    /// The field as `TextProbe.reading` reads it.
    func read(_ snapshot: Erasure.Snapshot) -> Erasure.Reading {
        clock += readTime
        let location = text.utf16.count
        let leadStart = snapshot.start - snapshot.lead.utf16.count
        let gap = location - snapshot.start
        return Erasure.Reading(
            location: location, lead: Self.slice(text, max(0, leadStart)..<min(snapshot.start, location)),
            remaining: gap > 0 && gap <= snapshot.word.utf16.count ? Self.slice(text, snapshot.start..<location) : "")
    }

    /// `Erasure.confirm` on this field; text typed back is posted like any key.
    func confirm(_ snapshot: Erasure.Snapshot, deadline: Double? = nil,
                 timing: Erasure.Timing = Erasure.Timing()) -> Erasure.Outcome {
        Erasure.confirm(
            snapshot, timing: timing, deadline: deadline ?? clock + 2,
            now: { self.clock },
            pause: { self.advance(by: 0.002) },
            read: { self.read(snapshot) },
            restore: { self.typedBack.append($0); self.post(.text($0)) })
    }

    static func slice(_ text: String, _ range: Range<Int>) -> String {
        guard range.lowerBound < range.upperBound else { return "" }
        let units = Array(text.utf16)
        guard range.lowerBound < units.count else { return "" }
        return String(decoding: units[range.lowerBound..<min(range.upperBound, units.count)], as: UTF16.self)
    }
}
