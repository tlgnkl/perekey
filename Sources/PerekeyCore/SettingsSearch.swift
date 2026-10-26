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
    /// What the window must show for the row to be there: names of the flags that must be set.
    /// Empty: always.
    public var requires: Set<String>

    public init(section: Section, anchor: String, texts: [String], requires: Set<String> = []) {
        self.section = section
        self.anchor = anchor
        self.texts = texts.map(SearchText.normalize)
        self.requires = requires
    }
}

/// The entries of all sections, in the order the person meets them.
public struct SettingsSearch<Section: Hashable & Sendable>: Sendable {
    public let entries: [SearchEntry<Section>]

    public init(entries: [SearchEntry<Section>]) {
        self.entries = entries
    }

    /// The entries that match `query`, in order. None for a blank query. Entries that
    /// need a flag outside `available` are not in the window and do not match.
    public func matches(for query: String, available: Set<String>? = nil) -> [SearchEntry<Section>] {
        let needle = SearchText.needle(for: query)
        guard !needle.isEmpty else { return [] }
        return entries.filter { entry in
            (available.map(entry.requires.isSubset(of:)) ?? true) && entry.texts.contains { $0.contains(needle) }
        }
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

/// The search of one window: the query, which rows are there, the matches and
/// where Return is in them. The window's model wraps it.
public struct SearchSession<Section: Hashable & Sendable>: Sendable {
    public let search: SettingsSearch<Section>
    public private(set) var query = ""
    public private(set) var available: Set<String>
    public private(set) var matches: [SearchEntry<Section>] = []
    private var walk = SearchWalk()

    public init(search: SettingsSearch<Section>, available: Set<String> = []) {
        self.search = search
        self.available = available
    }

    /// Whether a query is typed: the sidebar then dims and counts.
    public var isActive: Bool { !SearchText.needle(for: query).isEmpty }

    public func count(in section: Section) -> Int {
        matches.count { $0.section == section }
    }

    /// A new query starts the walk over.
    public mutating func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        walk.reset()
        refresh()
    }

    /// The window shows other rows now (a model finished downloading, a setting changed).
    public mutating func setAvailable(_ flags: Set<String>) {
        guard flags != available else { return }
        available = flags
        refresh()
    }

    private mutating func refresh() {
        let shown = matches
        matches = search.matches(for: query, available: available)
        // The matches changed under the walk: it starts over, or it would skip one.
        if matches.map(\.anchor) != shown.map(\.anchor) { walk.reset() }
    }

    /// Return: the next match, around.
    public mutating func next() -> SearchEntry<Section>? {
        walk.advance(count: matches.count).map { matches[$0] }
    }

    /// A click on a section: its first match, and Return goes on from there.
    public mutating func first(in section: Section) -> SearchEntry<Section>? {
        guard let index = matches.firstIndex(where: { $0.section == section }) else { return nil }
        walk.jump(to: index)
        return matches[index]
    }
}
