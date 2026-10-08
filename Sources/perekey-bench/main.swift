// SPDX-License-Identifier: GPL-3.0-or-later
//
// Benchmarks InputMachine on a recorded-like typing session.
//
//   perekey-bench <fixtures dir> [result.json]
//
// Prints the mean time per event (best of several batch runs) and the 99th
// percentile of single events. Fails when the 99th percentile exceeds the 1 ms
// tap callback budget. scripts/bench.sh compares the mean with a base commit.

import Foundation
import PerekeyCore

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: perekey-bench <fixtures dir> [result.json]\n".utf8))
    exit(2)
}

func layout(_ name: String) -> LayoutMap {
    let url = URL(fileURLWithPath: arguments[1]).appendingPathComponent("\(name).json")
    return try! JSONDecoder().decode(LayoutMap.self, from: Data(contentsOf: url))
}

let abc = layout("ABC")
let russian = layout("Russian")

/// A session: words in the wrong layout, spaces, a retype every few words, its
/// synthetic events and the layout confirmation, typos with Backspace, arrows.
func session() -> [InputEvent] {
    let words = ["ghbdtn", "vbh", ",eltn", "hello", "world", "[jhjij", "'nj", "ds,jh", "code", "rjl"]
    var events: [InputEvent] = []
    var time = 0.0
    var seq: UInt32 = 1
    var layout = abc
    func key(_ keyCode: UInt16, flags: UInt64 = 0, origin: EventOrigin = .user) {
        time += 0.06
        events.append(.key(KeyEvent(.down, keyCode: keyCode, flags: flags, origin: origin), time: time))
        time += 0.03
        events.append(.key(KeyEvent(.up, keyCode: keyCode, flags: flags, origin: origin), time: time))
    }
    for round in 0..<2000 {
        let word = words[round % words.count]
        for stroke in abc.strokes(word) { key(stroke.keyCode) }
        if round % 7 == 3 { key(2); key(KeyCode.delete) }
        if round % 4 == 0 {
            time += 0.3
            events.append(.flagsChanged(keyCode: 58, flags: 0x8_0020, origin: .user, time: time))
            time += 0.08
            events.append(.flagsChanged(keyCode: 58, flags: 0, origin: .user, time: time))
            let count = word.count * 2
            for index in 0..<count { key(0, origin: .own(seq: seq, last: index == count - 1)) }
            seq += 1
            layout = layout.id == abc.id ? russian : abc
            events.append(.layoutChanged(layout.id))
        }
        key(KeyCode.space)
        if round % 25 == 24 { key(KeyCode.leftArrow) }
    }
    return events
}

extension LayoutMap {
    func strokes(_ text: String) -> [KeyStroke] { text.compactMap { stroke(for: $0) } }
}

let events = session()
let clock = ContinuousClock()
var sink = 0

func nanoseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1e9 + Double(duration.components.attoseconds) / 1e9
}

// Throughput: the session 30 times as one batch (tens of milliseconds, long
// enough to be stable), best of 7 runs.
var mean = Double.infinity
for _ in 0..<7 {
    let elapsed = clock.measure {
        for _ in 0..<30 {
            var machine = InputMachine(layouts: [abc, russian], currentLayout: abc.id)
            for event in events { sink &+= machine.handle(event).effects.count }
        }
    }
    mean = min(mean, nanoseconds(elapsed) / Double(events.count * 30))
}

// Latency: every event timed on its own, clock overhead included.
var samples: [Double] = []
samples.reserveCapacity(events.count * 3)
for _ in 0..<3 {
    var machine = InputMachine(layouts: [abc, russian], currentLayout: abc.id)
    for event in events {
        let start = clock.now
        sink &+= machine.handle(event).effects.count
        samples.append(nanoseconds(clock.now - start))
    }
}
samples.sort()
let p99 = samples[samples.count * 99 / 100]
print(String(format: "%d events: mean %.0f ns, p99 %.0f ns, max %.0f ns (sink %d)",
             events.count, mean, p99, samples.last!, sink))

var failed = false
if p99 > 1_000_000 {
    print("FAIL: p99 exceeds the 1 ms tap callback budget")
    failed = true
}
if arguments.count >= 3 {
    try JSONEncoder().encode(["mean": mean, "p99": p99]).write(to: URL(fileURLWithPath: arguments[2]))
}
exit(failed ? 1 : 0)
