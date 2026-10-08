// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation
import PerekeyCore

/// The statistics file: `UsageStats` as JSON in Application Support, next to the
/// settings. An unreadable file is dropped: counters are not worth a recovery path.
public struct UsageStatsFile: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Perekey", directoryHint: .isDirectory)
            .appending(path: "statistics.json", directoryHint: .notDirectory)
    }

    public init(url: URL = UsageStatsFile.defaultURL) {
        self.url = url
    }

    public func load() -> UsageStats {
        guard let data = try? Data(contentsOf: url), let stats = try? JSONDecoder().decode(UsageStats.self, from: data)
        else { return UsageStats() }
        return stats
    }

    public func save(_ stats: UsageStats) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stats).write(to: url, options: .atomic)
    }

    public func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Counts corrections while the user has statistics on, and writes the file at
/// most once per `interval` (and on `flush()`, at quit), never per keystroke.
/// With statistics off it counts nothing and writes nothing.
@MainActor
@Observable
public final class UsageRecorder {
    public private(set) var stats: UsageStats
    /// Moves on every change, so views redraw.
    public private(set) var revision = 0

    @ObservationIgnored private let file: UsageStatsFile
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var lastWrite = Date.distantPast
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    public init(file: UsageStatsFile = UsageStatsFile(), interval: TimeInterval = 5,
                now: @escaping @MainActor () -> Date = { Date() }, isEnabled: @escaping @MainActor () -> Bool)
    {
        self.file = file
        self.interval = interval
        self.now = now
        self.isEnabled = isEnabled
        // The old file is read only if statistics are on: with them off nothing of it is used.
        stats = isEnabled() ? file.load() : UsageStats()
    }

    public func recordCorrection(_ kind: Correction.Kind) { record { $0.recordCorrection(kind, at: $1) } }
    public func recordUndo() { record { $0.recordUndo(at: $1) } }
    public func recordManualRetype() { record { $0.recordManualRetype(at: $1) } }

    /// Statistics were just switched on: bring the stored days in.
    public func enabled() {
        stats = file.load()
        revision += 1
    }

    /// The "Erase" button: counters and file are gone.
    public func erase() {
        pendingWrite?.cancel()
        pendingWrite = nil
        dirty = false
        stats.erase()
        file.erase()
        revision += 1
    }

    /// Writes now if there is something new and statistics are on.
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard dirty, isEnabled() else { return }
        dirty = false
        lastWrite = now()
        try? file.save(stats)
    }

    private func record(_ change: (inout UsageStats, Date) -> Void) {
        guard isEnabled() else { return }
        change(&stats, now())
        revision += 1
        dirty = true
        let wait = interval - now().timeIntervalSince(lastWrite)
        if wait <= 0 {
            flush()
        } else if pendingWrite == nil {
            pendingWrite = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }
}
