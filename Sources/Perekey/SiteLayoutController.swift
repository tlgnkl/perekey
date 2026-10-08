// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import os
import PerekeyCore
import PerekeyInput

/// Selects a site's default or remembered layout when the page in the front
/// browser changes host. A site rule wins over the browser's app rule: the app
/// rule applies on activation, the host arrives a moment later and overrides it.
///
/// The layout the user leaves a site with is remembered in memory, per run, by
/// the key of the rule that covers the host (so docs.github.com and
/// gist.github.com share the layout of github.com). URLs are never logged.
@MainActor
final class SiteLayoutController {
    private let sources: InputSources
    private let store: SettingsStore
    private let observer: SiteObserver
    private let log = Logger(subsystem: "app.perekey", category: "sites")
    /// The rule key of the page in front, `nil` outside a supported browser or without a rule.
    private var currentKey: String?
    private var lastLayouts: [String: LayoutID] = [:]

    init(sources: InputSources, store: SettingsStore) {
        self.sources = sources
        self.store = store
        let box = WeakBox<SiteLayoutController>()
        observer = SiteObserver { host in
            // Called on the AX thread.
            Task { @MainActor in box.value?.hostChanged(host) }
        }
        box.value = self
        observer.start()
    }

    /// The access to Accessibility may have just been granted.
    func refresh() { observer.refresh() }

    /// The user leaves the front app: remember the layout before the next app's
    /// rule changes it. The AX thread reports the missing host only later.
    func appLeft() {
        if let currentKey, let layout = sources.currentLayout { lastLayouts[currentKey] = layout }
    }

    func hostChanged(_ host: String?) {
        let match = host.flatMap { store.settings.siteRule(forHost: $0) }
        if match?.key == currentKey { return }
        if let currentKey, let layout = sources.currentLayout { lastLayouts[currentKey] = layout }
        currentKey = match?.key
        guard let match else { return }
        let target = match.rule.defaultLayout ?? (match.rule.rememberLastLayout ? lastLayouts[match.key] : nil)
        if let target, target != sources.currentLayout {
            sources.select(target)
            log.info("Site rule applied")
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

extension SettingsStore {
    /// Adds or edits one site's rule; `host` must be normalized.
    func updateSite(_ host: String, _ change: (inout SiteRule) -> Void) {
        update { settings in
            var rule = settings.sites[host] ?? SiteRule()
            change(&rule)
            settings.sites[host] = rule
        }
    }

    func removeSite(_ host: String) {
        update { $0.sites[host] = nil }
    }
}
