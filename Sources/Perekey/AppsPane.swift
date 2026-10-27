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
    /// Rows that flash after they are added.
    let found = FoundTracker()
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
    /// The language most typed in the app, once there is enough to say.
    var language: String?
    /// «Вставка диктовки»; `.automatic` without dictation.
    var insertion: DictationInsertion = .automatic
    var id: String { bundleID }
}

/// Settings → Apps: a mode and a layout rule per app. Structure follows the
/// Apps pane of `design/mockup.html`.
struct AppsPane: View {
    let store: SettingsStore
    let sources: InputSources
    /// Language counts; nil hides the language labels.
    let languages: LanguageStatsStore?
    #if PEREKEY_VOICE
    /// «Вставка диктовки» per app; nil, or dictation off, hides it.
    let voice: VoiceSettingsStore?
    #endif
    private let model: State<AppsPaneModel>

    #if PEREKEY_VOICE
    init(store: SettingsStore, sources: InputSources, languages: LanguageStatsStore? = nil,
         voice: VoiceSettingsStore? = nil, model: AppsPaneModel? = nil)
    {
        self.store = store
        self.sources = sources
        self.languages = languages
        self.voice = voice
        self.model = State(initialValue: model ?? AppsPaneModel())
    }
    #else
    init(store: SettingsStore, sources: InputSources, languages: LanguageStatsStore? = nil,
         model: AppsPaneModel? = nil)
    {
        self.store = store
        self.sources = sources
        self.languages = languages
        self.model = State(initialValue: model ?? AppsPaneModel())
    }
    #endif

    /// The dictation store while dictation is on.
    #if PEREKEY_VOICE
    private var dictation: VoiceSettingsStore? { voice?.isOn == true ? voice : nil }
    #endif

    private var pane: AppsPaneModel { model.wrappedValue }

    /// Apps with a user rule, installed apps with a built-in default, apps
    /// whose language is known from what was typed there, and apps with a
    /// «Вставка диктовки» of their own.
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
        if let languages {
            let listed = Set(list.map(\.bundleID))
            for id in languages.stats.apps.keys where !listed.contains(id) && languages.dominantLanguage(app: id) != nil {
                guard let url = AppInfo.url(bundleID: id) else { continue }
                list.append(AppEntry(bundleID: id, name: AppInfo.name(at: url), url: url,
                                     mode: AppModes.builtInMode(bundleID: id) ?? .auto, rule: nil))
            }
            for index in list.indices { list[index].language = languages.dominantLanguage(app: list[index].bundleID) }
        }
        #if PEREKEY_VOICE
        if let dictation {
            let chosen = dictation.settings.insertion
            let listed = Set(list.map(\.bundleID))
            for id in chosen.keys where !listed.contains(id) {
                guard let url = AppInfo.url(bundleID: id) else { continue }
                list.append(AppEntry(bundleID: id, name: AppInfo.name(at: url), url: url,
                                     mode: AppModes.builtInMode(bundleID: id) ?? .auto, rule: nil))
            }
            for index in list.indices { list[index].insertion = chosen[list[index].bundleID] ?? .automatic }
        }
        #endif
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
                .pkAnchor(SettingsSearchModel.titleAnchor)
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
                VStack(spacing: 0) {
                    columnHeaders
                    PKDivider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                                    VStack(spacing: 0) {
                                        if index > 0 { PKDivider(leading: 54) }
                                        row(entry)
                                            .pkFound(entry.bundleID, tracker: pane.found)
                                    }
                                    .pkRowTransition()
                                }
                            }
                            .pkListChanges(all.map(\.bundleID))
                        }
                        // A new row may sort out of view: bring it in.
                        .onChange(of: pane.found.ids) { old, new in
                            guard let added = new.subtracting(old).first else { return }
                            withAnimation(PK.Motion.easeOut(0.4)) { proxy.scrollTo(added, anchor: .center) }
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

    /// Names the two pickers of a row. The widths follow `AppRow`.
    private var columnHeaders: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Layout on entry").frame(width: AppRow.layoutWidth, alignment: .leading)
            Text("Mode").frame(width: AppRow.modeWidth, alignment: .leading)
            Color.clear.frame(width: AppRow.resetWidth, height: 1)
        }
        .font(PK.Font.captionStrong)
        .foregroundStyle(Color.pkInk2)
        .padding(.horizontal, PK.Space.md)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    private func row(_ entry: AppEntry) -> AppRow {
        #if PEREKEY_VOICE
        AppRow(entry: entry, store: store, sources: sources, languages: languages, voice: dictation)
        #else
        AppRow(entry: entry, store: store, sources: sources, languages: languages)
        #endif
    }

    private func add(_ app: AppCandidate) {
        pane.found.mark(app.bundleID)
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
    static let layoutWidth: CGFloat = 196
    static let modeWidth: CGFloat = 124
    static let resetWidth: CGFloat = 18

    let entry: AppEntry
    let store: SettingsStore
    let sources: InputSources
    let languages: LanguageStatsStore?
    #if PEREKEY_VOICE
    /// Nil hides «Вставка диктовки».
    var voice: VoiceSettingsStore?
    #endif

    /// Narrower by the dictation menu, so the app's name keeps its room.
    private var layoutWidth: CGFloat {
        #if PEREKEY_VOICE
        if voice != nil { return Self.layoutWidth - Self.resetWidth }
        #endif
        return Self.layoutWidth
    }

    /// The reset removes «Вставка диктовки» too, where the row shows it.
    private var resetHelp: String {
        #if PEREKEY_VOICE
        if voice != nil { return voiceString("Remove the rule and the dictation input") }
        #endif
        return String(localized: "Remove the rule")
    }

    /// The row has a rule to remove: its mode and layout, or its dictation input.
    private var hasRule: Bool { entry.rule != nil || entry.insertion != .automatic }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppInfo.icon(at: entry.url))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(PK.Font.body).foregroundStyle(Color.pkInk).lineLimit(1)
                Group {
                    // An app listed for its language alone has no rule to name.
                    if entry.rule != nil || AppModes.builtInMode(bundleID: entry.bundleID) != nil {
                        Text(entry.rule == nil ? String(localized: "Built-in default") : String(localized: "Your rule"))
                    }
                    #if PEREKEY_VOICE
                    if voice != nil, let caption = Self.insertionCaption(entry.insertion) { Text(caption) }
                    #endif
                    if let language = entry.language {
                        // "Reset" goes under the language when the row is narrow.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { languageCaption(language) }
                            VStack(alignment: .leading, spacing: 1) { languageCaption(language) }
                        }
                    }
                }
                .font(PK.Font.caption)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
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
            .frame(width: layoutWidth)
            Picker("Mode", selection: modeBinding) {
                ForEach(AppMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: Self.modeWidth)
            #if PEREKEY_VOICE
            if voice != nil { insertionMenu }
            #endif
            Button {
                store.resetRule(for: entry.bundleID)
                #if PEREKEY_VOICE
                voice?.update { $0.insertion[entry.bundleID] = nil }
                #endif
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: Self.resetWidth)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pkIndigoInk)
            .help(resetHelp)
            .accessibilityLabel(resetHelp)
            .opacity(hasRule ? 1 : 0)
            .disabled(!hasRule)
        }
        .padding(.horizontal, PK.Space.md)
        .padding(.vertical, 8)
    }

    #if PEREKEY_VOICE
    /// «Вставка диктовки»: a menu behind a microphone, as the row has no room for a third picker.
    private var insertionMenu: some View {
        Menu {
            Picker(voiceString("Dictation input"), selection: insertionBinding) {
                ForEach(DictationInsertion.allCases, id: \.self) { Text(Self.insertionTitle($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: entry.insertion == .automatic ? "mic" : "mic.fill")
                .frame(width: Self.resetWidth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: Self.resetWidth)
        .foregroundStyle(Color.pkIndigoInk)
        .help(voiceString("Dictation input"))
        .accessibilityLabel(voiceString("Dictation input"))
        .accessibilityValue(Self.insertionTitle(entry.insertion))
    }

    static func insertionTitle(_ insertion: DictationInsertion) -> String {
        switch insertion {
        case .automatic: voiceString("Automatic")
        case .paste: voiceString("Paste (⌘V)")
        case .typing: voiceString("Type as keystrokes")
        }
    }

    /// Under the app's name when the user chose how dictation goes in.
    static func insertionCaption(_ insertion: DictationInsertion) -> String? {
        switch insertion {
        case .automatic: nil
        case .paste: voiceString("Dictation: pasted")
        case .typing: voiceString("Dictation: typed")
        }
    }

    private var insertionBinding: Binding<DictationInsertion> {
        Binding(
            get: { entry.insertion },
            set: { choice in
                voice?.update { $0.insertion[entry.bundleID] = choice == .automatic ? nil : choice }
            }
        )
    }
    #endif

    @ViewBuilder private func languageCaption(_ language: String) -> some View {
        Text(Self.mostly(language))
        Button("Reset") { languages?.reset(app: entry.bundleID) }
            .buttonStyle(.plain)
            .foregroundStyle(Color.pkIndigoInk)
            .help("Forget the languages typed in this app")
    }

    /// "Mostly Russian": the language most typed in the app.
    static func mostly(_ language: String) -> String {
        switch language {
        case "ru": String(localized: "Mostly Russian")
        case "en": String(localized: "Mostly English")
        default:
            String(localized: "Mostly \(Locale.current.localizedString(forLanguageCode: language) ?? language)")
        }
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
