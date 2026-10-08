// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import PerekeyCore

/// The last corrections for the menu, in memory only: nothing here is saved,
/// and the list is empty again after a launch. The logic is `CorrectionLog`.
@MainActor
@Observable
final class RecentCorrections {
    private(set) var log = CorrectionLog()
    /// Counts corrections; the capsule flashes whenever it changes.
    private(set) var flashes = 0

    func record(_ correction: Correction) {
        log.record(correction)
        flashes += 1
    }

    func undone(seq: UInt32) {
        log.markUndone(seq: seq)
    }

    #if DEBUG
    /// Snapshot helper: a ready-made log.
    convenience init(_ log: CorrectionLog) {
        self.init()
        self.log = log
    }
    #endif
}

extension Correction.Kind {
    /// SF Symbol of the correction's kind, in the menu list.
    var symbol: String {
        switch self {
        case .layout: "keyboard"
        case .typo: "pencil.line"
        case .capsLock: "capslock.fill"
        case .doubleCapitals: "textformat.size"
        case .abbreviation: "textformat.abc"
        case .yo: "e.square"
        }
    }

    var title: String {
        switch self {
        case .layout: String(localized: "Wrong layout")
        case .typo: String(localized: "Typo")
        case .capsLock: String(localized: "Caps Lock")
        case .doubleCapitals: String(localized: "Double capital")
        case .abbreviation: String(localized: "Abbreviation")
        case .yo: String(localized: "Letter ё")
        }
    }
}
