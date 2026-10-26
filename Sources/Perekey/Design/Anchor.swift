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

    func body(content: Content) -> some View {
        content.id(id).pkFlash(id)
    }
}

/// Only the highlight, for a group whose `id` sits on the outer view. The view
/// marks itself when the search targets it: one that is not in the window
/// cannot leave a mark that flashes later.
private struct SearchFlash: ViewModifier {
    let id: String
    @Environment(\.pkSearch) private var search

    func body(content: Content) -> some View {
        if let search {
            content
                .pkFound(id, tracker: search.found)
                .onChange(of: search.target, initial: true) { _, target in
                    if target?.anchor == id { search.found.mark(id) }
                }
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

    /// An `id` only when there is one: `.id(nil)` would give every such view the same identity.
    @ViewBuilder func pkID(_ id: String?) -> some View {
        if let id { self.id(id) } else { self }
    }
}
