// SPDX-License-Identifier: GPL-3.0-or-later
//
// Times the shared words of the voice dictionary in the personal lexicon store
// on 5000 Cyrillic records: `setSharedWords` (the fingerprints, on the main
// thread) and `withdraw` (the path of an undo or a retype).
//
//   swift build -c release --product perekey-shared-measure
//   .build/release/perekey-shared-measure
//
// Words are made up from a fixed generator; nothing is read or written.

import Foundation
import PerekeyCore
import PerekeyInput

let count = 5000
let letters = Array("абвгдежзиклмнопрстуфхцчшэюя").map(String.init)

func word(_ index: Int) -> String {
    var n = index
    var out = ""
    for _ in 0..<7 {
        out += letters[n % letters.count]
        n = n / letters.count + 3
    }
    return out + letters[index % letters.count] + String(letters[(index / 7) % letters.count])
}

@MainActor
func run() {
    let texts = (0..<count).map(word)
    precondition(Set(texts).count == count)
    let clock = ContinuousClock()
    func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    let store = PersonalLexiconStore(file: nil, keys: MemoryLexiconKeyStore(), today: { 20000 })
    store.setEnabled(true)

    var setTimes: [Double] = []
    for round in 0..<15 {
        // A new list each round: the same list is skipped.
        let list = round % 2 == 0 ? texts : Array(texts.reversed())
        setTimes.append(ms(clock.measure { store.setSharedWords(list) }))
    }
    var withdrawTimes: [Double] = []
    for index in stride(from: 0, to: 1000, by: 50) {
        let ref = PersonalWordRef(text: texts[index], language: "ru")
        withdrawTimes.append(ms(clock.measure { store.withdraw(ref) }))
    }
    func line(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        print(String(format: "%@: n=%d min %.1f ms, median %.1f ms, mean %.1f ms, max %.1f ms", name, values.count,
                     sorted[0], sorted[sorted.count / 2], mean, sorted.last!))
    }
    print("records: \(count) (Cyrillic)")
    line("setSharedWords", setTimes)
    line("withdraw (first, then the rest)", withdrawTimes)
    print("first withdraw: \(String(format: "%.1f", withdrawTimes[0])) ms")
}

MainActor.assumeIsolated { run() }
