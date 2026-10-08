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

// The classifier: two readings of every word of the session, in the budget
// of a single key stroke. PEREKEY_MODEL names a real model; without it a
// small model is built here, which exercises the same code paths.
let model: LanguageModel
if let path = ProcessInfo.processInfo.environment["PEREKEY_MODEL"] {
    model = try ModelFile.load(path)
} else {
    var builder = ModelBuilder()
    builder.addLanguage("ru", alphabet: "абвгдеёжзийклмнопрстуфхцчшщъыьэюя-")
    builder.addLanguage("en", alphabet: "abcdefghijklmnopqrstuvwxyz'-")
    for word in ["привет", "мир", "будет", "хорошо", "это", "выбор", "код", "а", "и", "не", "что", "как"] {
        builder.addForm(word, language: "ru", rank: 200, weight: 100)
    }
    for word in ["hello", "world", "code", "the", "a", "i", "and", "is", "to", "of", "keyboard", "layout"] {
        builder.addForm(word, language: "en", rank: 200, weight: 100)
    }
    model = try LanguageModel(bytes: builder.build())
}
let classifier = Classifier(model: model)
let words = ["ghbdtn", "vbh", ",eltn", "hello", "world", "[jhjij", "'nj", "ds,jh", "code", "rjl",
             "https://example.com/path", "Ghb1dtn!", "xkqzp", "f", "клавиатура", "руддщ"]
let wordStrokes = words.map { abc.strokes($0) + [KeyStroke(KeyCode.space)] }
var classifierMean = Double.infinity
for _ in 0..<7 {
    let elapsed = clock.measure {
        for _ in 0..<2000 {
            for strokes in wordStrokes {
                sink &+= classifier.classify(strokes, typed: abc, other: russian).score > 0 ? 1 : 0
                sink &+= classifier.impossiblePrefix(strokes, typed: abc, other: russian) ? 1 : 0
            }
        }
    }
    classifierMean = min(classifierMean, nanoseconds(elapsed) / Double(wordStrokes.count * 2000))
}
var classifierSamples: [Double] = []
for _ in 0..<200 {
    for strokes in wordStrokes {
        let start = clock.now
        sink &+= classifier.classify(strokes, typed: abc, other: russian).score > 0 ? 1 : 0
        classifierSamples.append(nanoseconds(clock.now - start))
    }
}
classifierSamples.sort()
let classifierP99 = classifierSamples[classifierSamples.count * 99 / 100]
print(String(format: "classifier: mean %.0f ns per word (with the prefix check), p99 %.0f ns (sink %d)",
             classifierMean, classifierP99, sink))
if classifierP99 > 100_000 {
    print("FAIL: classifier p99 exceeds 100 µs")
    failed = true
}

// Automatic switching: the machine with the classifier on, typing a mix of
// words in the right and the wrong layout. The driver plays the system layer:
// it posts each retype, sends its synthetic keys back, confirms the layout and
// replays held keys, so switches, fences, replays and undos all run. Every
// handled event is timed on its own, classification included.
struct AutoswitchRun {
    var events = 0
    var samples: [Double] = []
    var corrections = 0
}

func autoswitchSession(rounds: Int) -> AutoswitchRun {
    var run = AutoswitchRun()
    run.samples.reserveCapacity(rounds * 80)
    var machine = InputMachine(layouts: [abc, russian], currentLayout: abc.id, classifier: classifier)
    _ = machine.handle(.focusChanged(Focus(bundleID: "app.perekey.bench")))
    var time = 0.0
    var held: [KeyEvent] = []
    var retypes: [Retype] = []
    var selected: LayoutID?
    // Physical keys of each word in the layout it is meant for: when the
    // other layout is selected, the word comes out wrong and gets switched.
    let words: [(String, LayoutMap)] = [
        ("привет", russian), ("мир", russian), ("hello", abc), ("world", abc), ("хорошо", russian),
        ("будет", russian), ("code", abc), ("выбор", russian), ("это", russian), ("keyboard", abc),
        ("layout", abc), ("спасибо", russian), ("https://example.com", abc), ("the", abc), ("и", russian),
    ]

    func handle(_ event: InputEvent) -> Output {
        let start = clock.now
        let output = machine.handle(event)
        run.samples.append(nanoseconds(clock.now - start))
        run.events += 1
        for effect in output.effects {
            switch effect {
            case let .selectLayout(id): selected = id
            case let .retype(retype): retypes.append(retype)
            case .corrected: run.corrections += 1
            case .releaseHeld:
                let replay = held
                held.removeAll()
                for var event in replay {
                    event.origin = .replayed
                    key(event)
                }
            default: break
            }
        }
        return output
    }
    func key(_ event: KeyEvent) {
        time += 0.0005
        if handle(.key(event, time: time)).disposition == .hold { held.append(event) }
    }
    func settle() {
        while selected != nil || !retypes.isEmpty {
            if !retypes.isEmpty {
                let retype = retypes.removeFirst()
                guard machine.pendingRetypeSeq == retype.seq else { continue }
                time += 0.001
                _ = handle(.retypePosted(seq: retype.seq, time: time))
                let count = retype.deleteCount + retype.keys.count
                for index in 0..<count {
                    key(KeyEvent(.down, keyCode: 0, origin: .own(seq: retype.seq, last: index == count - 1)))
                }
            }
            if let id = selected {
                selected = nil
                _ = handle(.layoutChanged(id))
            }
        }
    }
    func press(_ stroke: KeyStroke) {
        let flags: UInt64 = stroke.modifiers.contains(.shift) ? 0x2_0002 : 0
        time += 0.06
        key(KeyEvent(.down, keyCode: stroke.keyCode, flags: flags))
        time += 0.03
        key(KeyEvent(.up, keyCode: stroke.keyCode, flags: flags))
        settle()
    }

    for round in 0..<rounds {
        let (word, layout) = words[round % words.count]
        for stroke in layout.strokes(word) { press(stroke) }
        press(KeyStroke(KeyCode.space))
        // Now and then the user takes a switch back.
        if round % 11 == 5 { press(KeyStroke(KeyCode.delete)) }
    }
    return run
}

var autoswitch = autoswitchSession(rounds: 6000)
autoswitch.samples.sort()
let autoswitchMean = autoswitch.samples.reduce(0, +) / Double(autoswitch.samples.count)
let autoswitchP99 = autoswitch.samples[autoswitch.samples.count * 99 / 100]
print(String(format: "autoswitch: %d events, %d corrections: mean %.0f ns, p99 %.0f ns, max %.0f ns",
             autoswitch.events, autoswitch.corrections, autoswitchMean, autoswitchP99, autoswitch.samples.last!))
if autoswitchP99 > 1_000_000 {
    print("FAIL: autoswitch p99 exceeds the 1 ms tap callback budget")
    failed = true
}
if autoswitch.corrections == 0 {
    print("FAIL: the autoswitch session switched nothing")
    failed = true
}

if arguments.count >= 3 {
    try JSONEncoder().encode(["mean": mean, "p99": p99, "classifier": classifierMean, "classifierP99": classifierP99,
                              "autoswitch": autoswitchMean, "autoswitchP99": autoswitchP99])
        .write(to: URL(fileURLWithPath: arguments[2]))
}
exit(failed ? 1 : 0)
