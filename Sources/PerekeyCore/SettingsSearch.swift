// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How the search field of Settings compares text. No SwiftUI: the window gives
/// it the localized strings of the rows, and it says which rows match.
public enum SearchText {
    /// Lowercase, «ё» as «е», single spaces. Case and «ё» do not matter to the search.
    public static func normalize(_ text: String) -> String {
        let folded = text.lowercased().replacingOccurrences(of: "ё", with: "е")
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a row's text must contain: the normalized query, without its last
    /// letter from five letters on, so that «пароль» finds «паролей». Empty for a blank query.
    public static func needle(for query: String) -> String {
        let text = normalize(query)
        return text.count >= 5 ? String(text.dropLast()) : text
    }
}

/// A row or a group of Settings the search can find.
public struct SearchEntry<Section: Hashable & Sendable>: Sendable {
    public var section: Section
    /// The `id` of the row or group in its pane: what the pane scrolls to and flashes.
    public var anchor: String
    /// The texts a query is looked for in: the localized title and the English one.
    public var texts: [String]

    public init(section: Section, anchor: String, texts: [String]) {
        self.section = section
        self.anchor = anchor
        self.texts = texts.map(SearchText.normalize)
    }
}

/// The entries of all sections, in the order the person meets them.
public struct SettingsSearch<Section: Hashable & Sendable>: Sendable {
    public let entries: [SearchEntry<Section>]

    public init(entries: [SearchEntry<Section>]) {
        self.entries = entries
    }

    /// The entries that match `query`, in order. None for a blank query.
    public func matches(for query: String) -> [SearchEntry<Section>] {
        let needle = SearchText.needle(for: query)
        guard !needle.isEmpty else { return [] }
        return entries.filter { entry in entry.texts.contains { $0.contains(needle) } }
    }
}

/// Return walks the matches and wraps around; a new query starts the walk again.
public struct SearchWalk: Equatable, Sendable {
    /// The match shown last; `nil` before the first Return.
    public private(set) var position: Int?

    public init() {}

    /// The index of the next match among `count`, or `nil` when there is none.
    public mutating func advance(count: Int) -> Int? {
        guard count > 0 else {
            position = nil
            return nil
        }
        let next = ((position ?? -1) + 1) % count
        position = next
        return next
    }

    public mutating func reset() { position = nil }

    /// Continues from `index`: a click on a section jumps to a match, and Return goes on from there.
    public mutating func jump(to index: Int) { position = index }
}
