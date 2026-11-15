// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// Whose key is it, by the `eventSourceUserData` it carries. The guard stops on a person's key only.
public enum HumanKey {
    /// What the bench writes into `eventSourceUserData` of every key it posts. Not Perekey's mark
    /// (`SyntheticMark`): Perekey must go on taking these keys as a person's, which is the point of the test.
    public static let benchMark: Int64 = 0x4245 << 48 // "BE"

    /// A person's key has neither the bench's mark nor any mark of Perekey. Every `SyntheticMark` is
    /// Perekey's own, `.replayed` too: Perekey posts again the keys it held, and that includes the bench's,
    /// overwriting the mark. A person's key that Perekey held is seen before it is held, by a tap at the
    /// level of the hardware, where it still has no mark.
    public static func isHuman(userData: Int64) -> Bool {
        if userData == benchMark { return false }
        return SyntheticMark(userData: userData) == nil
    }
}
