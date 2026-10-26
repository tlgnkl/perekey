// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import PerekeyCore

/// The state of the Settings search: the query, the matches, where Return is in
/// them and where the panes should scroll and flash. The matching itself is
/// `SettingsSearch` in PerekeyCore.
@MainActor
@Observable
final class SettingsSearchModel {
    /// The anchor every pane gives its title.
    nonisolated static let titleAnchor = "title"

    /// A place the open pane scrolls to. `serial` makes the same place count again.
    struct Target: Equatable {
        let anchor: String
        let serial: Int
    }

    private(set) var query = ""
    private(set) var matches: [SearchEntry<SettingsSection>] = []
    private(set) var target: Target?
    /// What flashes: the pane's rows read it through `pkAnchor`.
    let found = FoundTracker()

    @ObservationIgnored private var walk = SearchWalk()
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let search: SettingsSearch<SettingsSection>

    init(search: SettingsSearch<SettingsSection> = SettingsIndex.search) {
        self.search = search
    }

    /// Whether a query is typed: the sidebar then dims and counts.
    var isActive: Bool { !SearchText.needle(for: query).isEmpty }

    var hasNoMatches: Bool { isActive && matches.isEmpty }

    func count(in section: SettingsSection) -> Int {
        matches.count { $0.section == section }
    }

    /// A new query starts the walk over.
    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        matches = search.matches(for: text)
        walk.reset()
        target = nil
    }

    /// Return: the next match, around.
    func next() -> SearchEntry<SettingsSection>? {
        walk.advance(count: matches.count).map { matches[$0] }
    }

    /// A click on a section: its first match, and Return goes on from there.
    func first(in section: SettingsSection) -> SearchEntry<SettingsSection>? {
        guard let index = matches.firstIndex(where: { $0.section == section }) else { return nil }
        walk.jump(to: index)
        return matches[index]
    }

    /// Scrolls the open pane to `entry` and flashes it. The pane must show `entry.section` by then.
    func reveal(_ entry: SearchEntry<SettingsSection>) {
        found.mark(entry.anchor)
        serial += 1
        target = Target(anchor: entry.anchor, serial: serial)
    }

    /// The person picked a pane: it opens at its top, not at the last match. A highlight
    /// that plays is not cut: `FoundTracker` takes its mark back when it ends.
    func forget() { target = nil }
}
