// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Search anchors

private struct SearchKey: EnvironmentKey {
    static let defaultValue: SettingsSearchModel? = nil
}

extension EnvironmentValues {
    /// The search of the Settings window; `nil` outside it (a preview, a snapshot).
    var pkSearch: SettingsSearchModel? {
        get { self[SearchKey.self] }
        set { self[SearchKey.self] = newValue }
    }
}

/// Gives a row or a group the `id` the search scrolls to, and lets it play the
/// found highlight when the search lands on it.
private struct SearchAnchor: ViewModifier {
    let id: String
    @Environment(\.pkSearch) private var search

    func body(content: Content) -> some View {
        if let search {
            content.id(id).pkFound(id, tracker: search.found)
        } else {
            content.id(id)
        }
    }
}

/// Only the highlight, for a group whose `id` sits on the outer view.
private struct SearchFlash: ViewModifier {
    let id: String
    @Environment(\.pkSearch) private var search

    func body(content: Content) -> some View {
        if let search {
            content.pkFound(id, tracker: search.found)
        } else {
            content
        }
    }
}

extension View {
    /// Marks this view as a place of the Settings search: `id` is its entry in `SettingsIndex`.
    /// `nil` marks nothing.
    @ViewBuilder func pkAnchor(_ id: String?) -> some View {
        if let id { modifier(SearchAnchor(id: id)) } else { self }
    }

    @ViewBuilder func pkFlash(_ id: String?) -> some View {
        if let id { modifier(SearchFlash(id: id)) } else { self }
    }
}
