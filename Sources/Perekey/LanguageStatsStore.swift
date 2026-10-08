// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import os
import PerekeyCore
import PerekeyInput

/// The language counts of apps and sites in memory, on the main thread. The
/// tap's tallies come in here and go to disk at once; the prior for the app
/// and site in front goes back to the tap (`InputController`).
@MainActor
@Observable
final class LanguageStatsStore {
    private(set) var stats: LanguageStats

    @ObservationIgnored private let file: LanguageStatsFile?
    @ObservationIgnored private let log = Logger(subsystem: "app.perekey", category: "languages")

    /// `file`: nil keeps the counts in memory only (snapshots, tests).
    init(file: LanguageStatsFile? = LanguageStatsFile()) {
        self.file = file
        var stats = file?.load() ?? LanguageStats()
        stats.prune(at: Self.now)
        self.stats = stats
    }

    static var now: Double { Date().timeIntervalSince1970 }

    func record(_ tally: LanguageTally) {
        stats.record(tally, at: Self.now)
        stats.prune(at: Self.now)
        save()
    }

    /// The context for the tap: the prior of the app and site, and the
    /// generation of the counts. Every reset changes it, so the observer
    /// sends a new one, and the words the tap counted before it are dropped.
    func context(app: String?, site: String?) -> LanguageContext {
        LanguageContext(app: app, site: site, prior: stats.prior(app: app, site: site, at: Self.now),
                        generation: stats.generation)
    }

    /// The language most typed in the app, once there is enough to say.
    func dominantLanguage(app: String) -> String? {
        stats.dominantLanguage(app: app, at: Self.now)
    }

    /// Forgets the app's counts; for a browser also those of every site.
    func reset(app: String) {
        stats.reset(app: app, sites: SiteObserver.browserBundleIDs.contains(app))
        save()
    }

    /// Forgets every app and site (Settings → Privacy).
    func resetAll() {
        stats.resetAll()
        save()
    }

    private func save() {
        do {
            try file?.save(stats)
        } catch {
            log.error("Cannot save language counts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
