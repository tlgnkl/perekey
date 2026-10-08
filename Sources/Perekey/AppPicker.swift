// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import SwiftUI

/// One app the picker can offer.
struct AppCandidate: Identifiable, Hashable {
    var bundleID: String
    var name: String
    var url: URL
    var isRunning: Bool
    var id: String { bundleID }

    /// The mode the app has without a user rule.
    @MainActor var defaultMode: AppMode {
        AppModes.builtInMode(bundleID: bundleID) ?? (AppInfo.isGame(at: url) ? .off : .auto)
    }
}

/// The picker's data: running apps, apps in the Applications folders, and
/// whatever Spotlight finds for the query.
@MainActor
@Observable
final class AppPickerModel {
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    var selection = 0
    private(set) var spotlightCount = 0
    private(set) var base: [AppCandidate] = []
    private(set) var spotlight: [AppCandidate] = []

    @ObservationIgnored private let useSpotlight: Bool
    @ObservationIgnored private var metadata: NSMetadataQuery?
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []

    /// `spotlight: false` skips `NSMetadataQuery` (snapshots).
    init(spotlight: Bool = true) {
        useSpotlight = spotlight
        base = Self.scan()
    }

    isolated deinit {
        metadata?.stop()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// The matches: running apps first, then the rest by name. Capped at 40.
    var results: [AppCandidate] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        func matches(_ app: AppCandidate) -> Bool {
            needle.isEmpty || app.name.localizedStandardContains(needle) || app.bundleID.localizedCaseInsensitiveContains(needle)
        }
        var seen = Set<String>()
        var list: [AppCandidate] = []
        for app in base + spotlight where matches(app) && seen.insert(app.bundleID).inserted {
            list.append(app)
        }
        list.sort {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Array(list.prefix(40))
    }

    /// The line above the results.
    var sourceLine: LocalizedStringResource {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "Running apps and Applications" }
        return "Running apps, Applications and Spotlight"
    }

    func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    // MARK: Sources

    static func scan() -> [AppCandidate] {
        var found: [String: AppCandidate] = [:]
        let own = Bundle.main.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.bundleIdentifier != own {
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { continue }
            found[id] = AppCandidate(bundleID: id, name: app.localizedName ?? AppInfo.name(at: url), url: url, isRunning: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities"].map { URL(fileURLWithPath: $0) } + [home]
        for folder in folders {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier, id != own, found[id] == nil else { continue }
                found[id] = AppCandidate(bundleID: id, name: AppInfo.name(at: url), url: url, isRunning: false)
            }
        }
        return Array(found.values)
    }

    private func queryChanged() {
        selection = 0
        guard useSpotlight else { return }
        let needle = query.trimmingCharacters(in: .whitespaces)
        metadata?.stop()
        guard needle.count >= 2 else {
            spotlight = []
            spotlightCount = 0
            return
        }
        let query = metadata ?? NSMetadataQuery()
        if metadata == nil {
            metadata = query
            for name in [Notification.Name("NSMetadataQueryDidFinishGatheringNotification"), Notification.Name("NSMetadataQueryDidUpdateNotification")] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.spotlightUpdated() }
                })
            }
        }
        query.predicate = NSPredicate(
            format: "kMDItemContentType == %@ AND kMDItemDisplayName CONTAINS[cd] %@",
            "com.apple.application-bundle", needle
        )
        query.start()
    }

    private func spotlightUpdated() {
        guard let metadata else { return }
        metadata.disableUpdates()
        defer { metadata.enableUpdates() }
        var list: [AppCandidate] = []
        for case let item as NSMetadataItem in metadata.results.prefix(60) {
            guard let path = item.value(forAttribute: kMDItemPath as String) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            list.append(AppCandidate(bundleID: id, name: AppInfo.name(at: url), url: url, isRunning: false))
        }
        spotlight = list
        spotlightCount = list.count
    }
}

/// The popover under "+": a search field and the results. Return adds the selected app.
struct AppPickerView: View {
    let model: AppPickerModel
    /// Apps that already have a row.
    let existing: Set<String>
    let onPick: (AppCandidate) -> Void

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: Bindable(model).query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { pickSelected(results) }
                    .onKeyPress(.downArrow) { model.move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1, count: results.count); return .handled }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Divider()
            Text(model.sourceLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if results.isEmpty {
                Text("No apps found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, app in
                                AppPickerRow(app: app, isSelected: index == model.selection, isAdded: existing.contains(app.bundleID))
                                    .pkCascade(index: index)
                                    .id(app.id)
                                    .onTapGesture { if !existing.contains(app.bundleID) { onPick(app) } }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .onChange(of: model.selection) { _, new in
                        if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                    }
                }
            }
        }
        .frame(width: 360, height: 360)
    }

    private func pickSelected(_ results: [AppCandidate]) {
        guard results.indices.contains(model.selection) else { return }
        let app = results[model.selection]
        if !existing.contains(app.bundleID) { onPick(app) }
    }
}

private struct AppPickerRow: View {
    let app: AppCandidate
    let isSelected: Bool
    let isAdded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(at: app.url))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).lineLimit(1)
                    if app.isRunning {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .accessibilityLabel("Running")
                    }
                }
                Text(verbatim: (app.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.7)
            }
            Spacer(minLength: 8)
            if isAdded {
                Image(systemName: "checkmark")
            } else {
                Text(app.defaultMode.title).font(.caption).opacity(0.7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected && !isAdded ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected && !isAdded ? Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255) : .clear)
        )
        .contentShape(Rectangle())
    }
}
