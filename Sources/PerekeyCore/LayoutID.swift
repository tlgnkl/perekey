// SPDX-License-Identifier: GPL-3.0-or-later

/// A keyboard layout, identified by its Text Input Sources ID,
/// e.g. `com.apple.keylayout.Russian` or `com.apple.keylayout.ABC`.
///
/// A language is not enough: one language can have several layouts
/// (ABC, U.S., Russian – PC), and the user may enable more than one.
public struct LayoutID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
