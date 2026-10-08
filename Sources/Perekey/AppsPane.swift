// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Observation
import PerekeyCore
import PerekeyInput
import SwiftUI

/// What the Apps pane shows and filters.
@MainActor
@Observable
final class AppsPaneModel {
    var search = ""
    /// `nil` shows every mode.
    var modeFilter: AppMode?
    var showPicker = false
    /// A fresh picker for each time the popover opens.
    var picker: AppPickerModel?
    /// Apps with a built-in default that are installed or running, found once.
    let builtIns: [AppCandidate]

    init(builtIns: [AppCandidate]? = nil) {
        self.builtIns = builtIns ?? AppPickerModel.scan().filter { AppModes.builtInMode(bundleID: $0.bundleID) != nil }
    }
}

/// One row: an app, its mode and its layout rule.
struct AppEntry: Identifiable {
    var bundleID: String
    var name: String
    var url: URL?
    var mode: AppMode
    var rule: AppRule?
    var id: String { bundleID }
}

/// Settings → Apps: a mode and a layout rule per app. Structure follows the
/// Apps pane of `design/mockup.html`.
struct AppsPane: View {
    let store: SettingsStore
    let sources: InputSources
    private let model: State<AppsPaneModel>

    init(store: SettingsStore, sources: InputSources, model: AppsPaneModel? = nil) {
        self.store = store
        self.sources = sources
        self.model = State(initialValue: model ?? AppsPaneModel())
    }

    private var pane: AppsPaneModel { model.wrappedValue }

    /// Apps with a user rule, then installed apps with a built-in default.
    private var entries: [AppEntry] {
        let apps = store.settings.apps
        var list: [AppEntry] = apps.map { id, rule in
            let url = AppInfo.url(bundleID: id)
            return AppEntry(bundleID: id, name: url.map(AppInfo.name(at:)) ?? id, url: url, mode: rule.mode, rule: rule)
        }
        for app in pane.builtIns where apps[app.bundleID] == nil {
            list.append(AppEntry(bundleID: app.bundleID, name: app.name, url: app.url,
                                 mode: AppModes.builtInMode(bundleID: app.bundleID) ?? .auto, rule: nil))
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let all = entries
        let needle = pane.search.trimmingCharacters(in: .whitespaces)
        let shown = all.filter { entry in
            (pane.modeFilter == nil || entry.mode == pane.modeFilter)
                && (needle.isEmpty || entry.name.localizedStandardContains(needle))
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps")
                .font(PK.Font.title)
                .tracking(-0.33)
                .foregroundStyle(Color.pkInk)
                .accessibilityAddTraits(.isHeader)
            Text("In terminals and code editors Perekey fixes only on your command. In games it is off.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
            toolbar(all)
            if shown.isEmpty {
                Text(all.isEmpty ? "No apps yet. Press + to add one." : "No apps match.")
                    .font(PK.Font.body)
                    .foregroundStyle(Color.pkInk2)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { PKDivider(leading: 54) }
                            AppRow(entry: entry, store: store, sources: sources)
                        }
                    }
                }
                .pkCard()
            }
        }
        .padding(.top, 20)
        .padding(.horizontal, PK.Space.pane)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toolbar(_ all: [AppEntry]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.pkInk2)
                TextField("Search the list", text: Bindable(pane).search)
                    .textFieldStyle(.plain)
                    .font(PK.Font.body)
            }
            .padding(.horizontal, 9)
            .frame(width: 160, height: 28)
            .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
            PKSegmented(items: [PKSegmented<AppMode?>.Item(value: nil, label: Text("All \(all.count)"))]
                + AppMode.allCases.map { mode in
                    PKSegmented<AppMode?>.Item(value: .some(mode), label: Text("\(String(localized: mode.title)) \(all.count { $0.mode == mode })"))
                }, selection: Bindable(pane).modeFilter, mini: true)
            Button {
                pane.picker = AppPickerModel()
                pane.showPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.pkInk)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.pkWashDeep))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add app")
            .popover(isPresented: Bindable(pane).showPicker, arrowEdge: .bottom) {
                if let picker = pane.picker {
                    AppPickerView(model: picker, existing: Set(all.map(\.bundleID))) { app in
                        add(app)
                        pane.showPicker = false
                    }
                }
            }
        }
    }

    private func add(_ app: AppCandidate) {
        store.updateRule(for: app.bundleID, base: app.defaultMode) { _ in }
        pane.search = ""
        pane.modeFilter = nil
    }
}

/// The layout choice of a row: leave it, return to the last one, or a fixed layout.
private enum LayoutChoice: Hashable {
    case none
    case remember
    case layout(LayoutID)
}

private struct AppRow: View {
    let entry: AppEntry
    let store: SettingsStore
    let sources: InputSources

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(at: entry.url))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(PK.Font.body).foregroundStyle(Color.pkInk).lineLimit(1)
                Text(entry.rule == nil ? "Built-in default" : "Your rule")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
            }
            Spacer(minLength: 8)
            Picker("Layout", selection: layoutChoice) {
                Text("Keep layout").tag(LayoutChoice.none)
                Text("Remember last").tag(LayoutChoice.remember)
                Divider()
                ForEach(sources.layouts, id: \.id) { layout in
                    Text(sources.name(of: layout.id)).tag(LayoutChoice.layout(layout.id))
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Picker("Mode", selection: modeBinding) {
                ForEach(AppMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 124)
            Button { store.resetRule(for: entry.bundleID) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pkIndigoInk)
            .help("Remove the rule")
            .accessibilityLabel("Remove the rule")
            .opacity(entry.rule == nil ? 0 : 1)
            .disabled(entry.rule == nil)
        }
        .padding(.horizontal, PK.Space.md)
        .padding(.vertical, 8)
    }

    private var modeBinding: Binding<AppMode> {
        Binding(
            get: { entry.mode },
            set: { mode in store.updateRule(for: entry.bundleID, base: entry.mode) { $0.mode = mode } }
        )
    }

    private var layoutChoice: Binding<LayoutChoice> {
        Binding(
            get: {
                guard let rule = entry.rule else { return .none }
                if let id = rule.defaultLayout { return .layout(id) }
                return rule.rememberLastLayout ? .remember : .none
            },
            set: { choice in
                store.updateRule(for: entry.bundleID, base: entry.mode) { rule in
                    switch choice {
                    case .none: (rule.defaultLayout, rule.rememberLastLayout) = (nil, false)
                    case .remember: (rule.defaultLayout, rule.rememberLastLayout) = (nil, true)
                    case let .layout(id): (rule.defaultLayout, rule.rememberLastLayout) = (id, false)
                    }
                }
            }
        )
    }
}
