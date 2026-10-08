// SPDX-License-Identifier: GPL-3.0-or-later

/// The value Perekey puts into `kCGEventSourceUserData` of the events it posts,
/// so the event tap can tell them from the user's input.
public enum SyntheticMark: Hashable, Sendable {
    /// Part of a retype. The event that ends it has `last` set: once the tap
    /// sees it, the application has received the whole retype.
    case own(seq: UInt32, last: Bool)
    /// User input that was held back during a retype and is now posted again.
    case replayed

    private static let magic: Int64 = 0x5045 // "PE"
    private static let lastBit: Int64 = 1 << 32
    private static let replayedBit: Int64 = 1 << 33

    public var userData: Int64 {
        switch self {
        case let .own(seq, last): Self.magic << 48 | (last ? Self.lastBit : 0) | Int64(seq)
        case .replayed: Self.magic << 48 | Self.replayedBit
        }
    }

    /// Reads the mark back; `nil` for events Perekey did not post.
    public init?(userData: Int64) {
        guard userData >> 48 == Self.magic else { return nil }
        if userData & Self.replayedBit != 0 {
            self = .replayed
        } else {
            self = .own(seq: UInt32(truncatingIfNeeded: userData), last: userData & Self.lastBit != 0)
        }
    }
}
