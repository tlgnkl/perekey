// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import Testing
@testable import PerekeyEvalKit

/// The guard stops on a person's key. Perekey posts again the keys it held, the bench's too, with its own
/// mark `.replayed` over the bench's: that must not stop a run.
struct HumanKeyTests {
    @Test func theBenchsMarkIsNotAPerson() {
        #expect(!HumanKey.isHuman(userData: HumanKey.benchMark))
    }

    @Test func everyMarkOfPerekeyIsNotAPerson() {
        let marks: [SyntheticMark] = [
            .own(seq: 0, last: false), .own(seq: 7, last: true), .own(seq: UInt32.max, last: true),
            .replayed,
            .typed(seq: 0, ack: false), .typed(seq: 3, ack: true), .typed(seq: UInt32.max, ack: false),
        ]
        for mark in marks {
            #expect(!HumanKey.isHuman(userData: mark.userData), "\(mark)")
        }
    }

    @Test func zeroIsAPerson() {
        #expect(HumanKey.isHuman(userData: 0))
    }

    @Test func anyOtherNumberIsAPerson() {
        for data: Int64 in [1, 42, -1, Int64.max, Int64.min, 0x4245, HumanKey.benchMark + 1, 0x5045, 0x5045 << 47] {
            #expect(HumanKey.isHuman(userData: data), "\(data)")
        }
    }

    @Test func theBenchsMarkIsNotPerekeys() {
        #expect(SyntheticMark(userData: HumanKey.benchMark) == nil)
    }
}
