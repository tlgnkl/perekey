// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import PerekeyCore

/// What the Settings window shows now, for the search: a row whose flag is not set is not in the window.
enum SettingsFlag: String, Hashable {
    /// The Voice tab has its controller.
    case voice
    /// … and this Mac can run voice input.
    case voiceSupported
    /// … and an administrator has not turned it off: the whole tab.
    case voiceActive
    case voiceText
    case voiceRecordings
    /// … and the Transcripts window can be opened from Settings.
    case voiceTranscripts
    case voiceSummaries
    /// The Voice modes tab has its store, and this Mac can run voice input.
    case voiceModes
    case voiceModesSupported
    /// More than two languages: General says which pairs switch by itself.
    case languageChoice
    case usage
    case statisticsOn
    case languageStats
}

/// The state of the Settings search for SwiftUI: `SearchSession` in PerekeyCore
/// (query, matches, the walk) plus where the panes should scroll and flash.
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

    private var session: SearchSession<SettingsSection>
    private(set) var target: Target?
    /// What flashes: a row marks itself when the search lands on it (`pkAnchor`),
    /// so a row that is not in the window is never marked.
    let found = FoundTracker()
    @ObservationIgnored private var serial = 0

    init(search: SettingsSearch<SettingsSection> = SettingsIndex.search) {
        session = SearchSession(search: search)
    }

    var query: String { session.query }
    var isActive: Bool { session.isActive }
    var hasNoMatches: Bool { session.isActive && session.matches.isEmpty }

    func count(in section: SettingsSection) -> Int { session.count(in: section) }

    func setQuery(_ text: String) {
        session.setQuery(text)
        target = nil
    }

    func setAvailable(_ flags: Set<SettingsFlag>) {
        session.setAvailable(Set(flags.map(\.rawValue)))
    }

    /// Return: the next match, around.
    func next() -> SearchEntry<SettingsSection>? { session.next() }

    /// A click on a section: its first match, and Return goes on from there.
    func first(in section: SettingsSection) -> SearchEntry<SettingsSection>? { session.first(in: section) }

    /// Scrolls the open pane to `entry`; the row flashes. The pane must show `entry.section` by then.
    func reveal(_ entry: SearchEntry<SettingsSection>) {
        serial += 1
        target = Target(anchor: entry.anchor, serial: serial)
    }

    /// The person picked a pane: it opens at its top, not at the last match.
    func forget() { target = nil }
}
