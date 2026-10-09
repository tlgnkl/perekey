// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyInput
import SwiftUI

/// The layout choice of a site: return to the last one, or a fixed layout.
private enum SiteLayoutChoice: Hashable {
    case none
    case remember
    case layout(LayoutID)

    init(_ rule: SiteRule) {
        if let id = rule.defaultLayout {
            self = .layout(id)
        } else {
            self = rule.rememberLastLayout ? .remember : .none
        }
    }

    func apply(to rule: inout SiteRule) {
        switch self {
        case .none: (rule.defaultLayout, rule.rememberLastLayout) = (nil, false)
        case .remember: (rule.defaultLayout, rule.rememberLastLayout) = (nil, true)
        case let .layout(id): (rule.defaultLayout, rule.rememberLastLayout) = (id, false)
        }
    }
}

/// Settings → Sites: a layout per site in Safari, Chrome, Arc, Brave, Edge and
/// Vivaldi. A site rule wins over the browser's rule in Apps.
struct SitesPane: View {
    let store: SettingsStore
    let sources: InputSources
    private let draft: State<String>
    private let draftChoice = State(initialValue: SiteLayoutChoice.remember)
    private let found = State(initialValue: FoundTracker())

    init(store: SettingsStore, sources: InputSources, initialDraft: String = "") {
        self.store = store
        self.sources = sources
        draft = State(initialValue: initialDraft)
    }

    private var sites: [(host: String, rule: SiteRule)] {
        store.settings.sites
            .map { (host: $0.key, rule: $0.value) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    private enum Validation { case empty, ok, invalid, duplicate }

    private var validation: Validation {
        let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard let host = SiteHost.normalized(text) else { return .invalid }
        return store.settings.sites[host] == nil ? .ok : .duplicate
    }

    var body: some View {
        PKPane(title: Text("Sites")) {
            Text("In Safari, Chrome, Arc, Brave, Edge and Vivaldi Perekey switches the layout when the page changes. It reads the address through Accessibility.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
            PKGroup(header: Text("Sites") + Text(count).foregroundStyle(Color.pkInk3)) {
                HStack(spacing: 8) {
                    TextField("Site", text: draft.projectedValue, prompt: Text(verbatim: "github.com"))
                        .labelsHidden()
                        .pkField()
                        .onSubmit(add)
                    layoutPicker(selection: draftChoice.projectedValue)
                    Button("Add", action: add)
                        .buttonStyle(.pkPrimary)
                        .disabled(validation != .ok)
                }
                .padding(PK.Space.md)
                if let message {
                    PKCallout(Text(verbatim: message.text), symbol: message.symbol, tone: .warn, quiet: true)
                }
                if sites.isEmpty {
                    PKDivider()
                    PKNote(Text("No sites yet. Subdomains follow their parent site."))
                }
                VStack(spacing: 0) {
                    ForEach(sites, id: \.host) { site in
                        VStack(spacing: 0) {
                            PKDivider()
                            PKRow(Text(verbatim: site.host)) {
                                HStack(spacing: 12) {
                                    layoutPicker(selection: binding(for: site.host))
                                    Button("Remove") { store.removeSite(site.host) }
                                        .buttonStyle(.pkLink)
                                        .fixedSize()
                                }
                            }
                            .pkFound(site.host, tracker: found.wrappedValue)
                        }
                        .pkRowTransition()
                    }
                }
                .pkListChanges(sites.map(\.host))
            }
        }
    }

    private var count: String { sites.isEmpty ? "" : "  \(sites.count)" }

    private func layoutPicker(selection: Binding<SiteLayoutChoice>) -> some View {
        Picker("Layout", selection: selection) {
            Text("Keep layout").tag(SiteLayoutChoice.none)
            Text("Remember last").tag(SiteLayoutChoice.remember)
            Divider()
            ForEach(sources.layouts, id: \.id) { layout in
                Text(sources.name(of: layout.id)).tag(SiteLayoutChoice.layout(layout.id))
            }
        }
        .labelsHidden()
        .frame(width: 196)
    }

    private func binding(for host: String) -> Binding<SiteLayoutChoice> {
        Binding(
            get: { SiteLayoutChoice(store.settings.sites[host] ?? SiteRule()) },
            set: { choice in store.updateSite(host) { choice.apply(to: &$0) } }
        )
    }

    private func add() {
        guard validation == .ok, let host = SiteHost.normalized(draft.wrappedValue) else { return }
        let choice = draftChoice.wrappedValue
        found.wrappedValue.mark(host)
        store.updateSite(host) { choice.apply(to: &$0) }
        draft.wrappedValue = ""
    }

    private var message: (text: String, symbol: String)? {
        switch validation {
        case .empty, .ok: nil
        case .invalid: (String(localized: "Enter a site address like github.com."), "xmark.circle")
        case .duplicate: (String(localized: "This site already has a rule."), "info.circle")
        }
    }
}
