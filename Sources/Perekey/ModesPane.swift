// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import AppKit
import PerekeyCore
import PerekeyInput
import PerekeyVoice
import PerekeyVoiceCore
import SwiftUI

/// Settings → Voice modes: the modes on the left, the chosen one on the
/// right, and below the servers language models run on, with their keys.
struct ModesPane: View {
    let store: VoiceModesStore
    let models: VoiceModelsController
    private let selectedState: State<String?>

    /// - Parameter selected: the mode shown first; the default one when nil.
    init(store: VoiceModesStore, models: VoiceModelsController, selected: String? = nil) {
        self.store = store
        self.models = models
        selectedState = State(initialValue: selected)
    }

    private var selected: String? {
        get { selectedState.wrappedValue }
        nonmutating set { selectedState.wrappedValue = newValue }
    }

    private var modeSet: VoiceModeSet { store.modes }

    var body: some View {
        PKPane(title: voiceText("Voice modes")) {
            if !models.isSupported {
                PKGroup {
                    PKNote(voiceText("Modes work together with voice. Voice input needs a Mac with Apple Silicon and macOS 15 or newer."))
                }
            } else {
                voiceText("A mode decides what happens to the text after recognition. Perekey picks it by itself: first by the site, then by the app.")
                    .font(PK.Font.caption)
                    .foregroundStyle(Color.pkInk2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                if store.isLocked {
                    PKGroup {
                        PKCallout(voiceText("These modes were written by another version of Perekey, and this one cannot read all of them. They are shown, not changed; update Perekey to edit them."))
                    }
                }
                PKGroup {
                    HStack(alignment: .top, spacing: 0) {
                        ModeList(store: store, selected: current?.id) { selected = $0 }
                            .frame(width: 184)
                        Rectangle().fill(Color.pkRule).frame(width: 0.5)
                        if let mode = current {
                            ModeEditor(store: store, models: models, mode: mode) { selected = nil }
                                .id(mode.id)
                        }
                    }
                }
                .disabled(store.isLocked)
                EndpointsGroup(store: store)
                    .disabled(store.isLocked)
            }
        }
    }

    private var current: VoiceMode? {
        modeSet.mode(selected) ?? modeSet.defaultMode
    }
}

// MARK: - The list

private struct ModeList: View {
    let store: VoiceModesStore
    let selected: String?
    let select: (String) -> Void
    @Namespace private var strip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(store.modes.modes) { mode in
                Button { select(mode.id) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: mode.name)
                                .font(.system(size: 13, weight: mode.id == selected ? .semibold : .regular))
                                .foregroundStyle(Color.pkInk)
                                .lineLimit(1)
                            Text(verbatim: where_(mode))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.pkInk3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let symbol = symbol(mode) {
                            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color.pkInk3)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 38)
                    .background {
                        if mode.id == selected {
                            Color.clear
                                .glassStrip(in: RoundedRectangle(cornerRadius: 9, style: .continuous), glow: false)
                                .matchedGeometryEffect(id: "strip", in: strip)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode.id == selected ? .isSelected : [])
            }
            Button {
                var added: VoiceMode?
                store.update { added = $0.addMode(name: voiceString("New mode")) }
                if let added { select(added.id) }
            } label: {
                voiceText("New mode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.pkIndigoInk)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            if !store.missingBuiltIns.isEmpty {
                Button { store.restoreBuiltIns() } label: {
                    voiceText("Bring back the built-in modes")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.pkIndigoInk)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .pkAnimation(PK.Motion.thumbSpring, value: selected)
    }

    /// "Везде по умолчанию", "Mail, mail.google.com", "Только из меню".
    private func where_(_ mode: VoiceMode) -> String {
        if mode.id == store.modes.defaultModeID { return voiceString("Everywhere by default") }
        let names = mode.bindings.prefix(3).map(ModeBindingName.short)
        guard !names.isEmpty else { return voiceString("From the menu only") }
        return names.joined(separator: ", ")
    }

    private func symbol(_ mode: VoiceMode) -> String? {
        let cloud = mode.endpoints.contains { store.modes.endpoint($0)?.endpointAddress?.isOnThisMac == false }
        if cloud { return "cloud" }
        return mode.refine == nil ? nil : "sparkles"
    }
}

/// How a binding is named: the app's name when it is installed, else its ID; a site by its host.
enum ModeBindingName {
    static func short(_ binding: ModeBinding) -> String {
        switch binding {
        case let .site(host): host
        case let .app(id): appName(id) ?? known[id] ?? id
        }
    }

    /// Names of the built-in modes' apps, for those not installed here.
    static let known: [String: String] = [
        "org.telegram.desktop": "Telegram Desktop", "ru.keepcoder.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp", "desktop.WhatsApp": "WhatsApp Desktop",
        "com.tinyspeck.slackmacgap": "Slack", "com.microsoft.Outlook": "Outlook",
        "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty",
        "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty", "com.github.wez.wezterm": "WezTerm",
        "com.microsoft.VSCode": "Visual Studio Code", "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed", "dev.zed.Zed-Preview": "Zed Preview",
        "com.apple.dt.Xcode": "Xcode", "com.sublimetext.4": "Sublime Text", "com.sublimetext.3": "Sublime Text 3",
        "com.panic.Nova": "Nova", "com.barebones.bbedit": "BBEdit", "com.jetbrains.": "JetBrains",
    ]

    static func appName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - The editor

/// The three places the language model step can be.
private enum RefineKind: Hashable {
    case none, local, cloud
}

private struct ModeEditor: View {
    let store: VoiceModesStore
    let models: VoiceModelsController
    let mode: VoiceMode
    let removed: () -> Void
    private let nameState = State<String>(initialValue: "")
    private var name: String {
        get { nameState.wrappedValue }
        nonmutating set { nameState.wrappedValue = newValue }
    }
    private let promptState = State<String>(initialValue: "")
    private var prompt: String {
        get { promptState.wrappedValue }
        nonmutating set { promptState.wrappedValue = newValue }
    }
    private let showPickerState = State<Bool>(initialValue: false)
    private var showPicker: Bool {
        get { showPickerState.wrappedValue }
        nonmutating set { showPickerState.wrappedValue = newValue }
    }
    private let pickerState = State<AppPickerModel?>(initialValue: nil)
    private var picker: AppPickerModel? {
        get { pickerState.wrappedValue }
        nonmutating set { pickerState.wrappedValue = newValue }
    }
    private let siteState = State<String>(initialValue: "")
    private var site: String {
        get { siteState.wrappedValue }
        nonmutating set { siteState.wrappedValue = newValue }
    }
    private let showSiteState = State<Bool>(initialValue: false)
    private var showSite: Bool {
        get { showSiteState.wrappedValue }
        nonmutating set { showSiteState.wrappedValue = newValue }
    }

    private var modeSet: VoiceModeSet { store.modes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(voiceText("Name")) {
                TextField(text: nameState.projectedValue) { voiceText("Name") }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitName() }
                    .onChange(of: name) { commitName() }
            }
            if let builtIn = BuiltInMode(rawValue: mode.id), let sample = ModeSample.of(builtIn) {
                field(voiceText("Example")) { sampleView(sample) }
            }
            speechField
            refineField
            if mode.refine != nil {
                promptField
                contextField
            }
            outputField
            bindingsField
            HStack {
                if mode.id != modeSet.defaultModeID {
                    Button { store.update { $0.defaultModeID = mode.id } } label: { voiceText("Use by default") }
                        .buttonStyle(.pkSmall)
                }
                Spacer()
                if modeSet.modes.count > 1 {
                    Button(role: .destructive) {
                        // A built-in mode comes back only by "Bring back the built-in modes".
                        guard BuiltInMode(rawValue: mode.id) == nil || confirmDelete() else { return }
                        store.update { $0.removeMode(mode.id) }
                        removed()
                    } label: { voiceText("Delete mode") }
                        .buttonStyle(.pkLink)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            name = mode.name
            prompt = mode.refine?.prompt ?? ""
        }
    }

    private func confirmDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = voiceString("Delete the mode “\(mode.name)”?")
        alert.informativeText = voiceString("It comes back with its settings reset by “Bring back the built-in modes”.")
        alert.addButton(withTitle: voiceString("Delete"))
        alert.addButton(withTitle: voiceString("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func sampleView(_ sample: ModeSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                voiceText("SAID").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.pkInk3)
                Text(verbatim: sample.said).font(.system(size: 12.5)).foregroundStyle(Color.pkInk2)
            }
            Text(verbatim: sample.result).font(.system(size: 14)).foregroundStyle(Color.pkInk)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.pkPlate))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
    }

    private func field<Content: View>(_ label: Text, detail: Text? = nil,
                                      @ViewBuilder content: () -> Content) -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            label.font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.pkInk2)
            content()
            if let detail {
                detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func update(_ change: (inout VoiceMode) -> Void) {
        store.updateMode(mode.id, change)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != mode.name else { return }
        update { $0.name = trimmed }
    }

    // MARK: Speech

    private var speechField: some View {
        let ready = models.statuses.filter { $0.state == .ready && $0.entry.engine.recognizes }
        let cloud = store.cloudDisabled ? [] : CloudSpeechModel.known
        return field(voiceText("Speech model"), detail: speechDetail) {
            Picker(selection: Binding(get: { mode.model ?? "" }, set: { id in
                update { $0.model = id.isEmpty ? nil : id }
                if let model = CloudSpeechModel(id: id) {
                    store.askConsentIfNeeded(mode: mode.id, endpoint: model.endpoint)
                }
            })) {
                voiceText("As in the Voice settings").tag("")
                Divider()
                ForEach(ready) { Text(verbatim: ModelNames.display($0.entry)).tag($0.id) }
                if !cloud.isEmpty {
                    Divider()
                    ForEach(cloud, id: \.id) { model in
                        let endpoint = modeSet.endpoint(model.endpoint)
                        let usable = endpoint.map(store.isUsable) ?? false
                        Text(verbatim: "\(model.displayName) · \(endpoint?.name ?? model.endpoint)"
                            + (usable ? "" : " — " + voiceString("needs a key")))
                            .tag(model.id)
                            .selectionDisabled(!usable)
                    }
                }
                if let model = mode.model, !ready.contains(where: { $0.id == model }),
                   !cloud.contains(where: { $0.id == model })
                {
                    // Not downloaded: the voice settings' model hears it meanwhile.
                    Text(verbatim: ModelCatalog.entry(id: model).map {
                        voiceString("\(ModelNames.display($0)) (not downloaded)")
                    } ?? model).tag(model)
                }
            } label: { voiceText("Speech model") }
                .labelsHidden()
                .frame(maxWidth: 300)
        }
    }

    private var speechDetail: Text? {
        guard let model = mode.model.flatMap(CloudSpeechModel.init(id:)),
              let host = modeSet.endpoint(model.endpoint)?.endpointAddress?.displayHost
        else { return nil }
        return voiceText("The audio of a dictation goes to \(host).")
    }

    // MARK: Language model

    private var kind: RefineKind {
        guard let refine = mode.refine else { return .none }
        return modeSet.endpoint(refine.endpoint)?.endpointAddress?.isOnThisMac == false ? .cloud : .local
    }

    private var localEndpoints: [VoiceEndpoint] {
        modeSet.endpoints.filter { $0.endpointAddress?.isOnThisMac == true }
    }

    private var cloudEndpoints: [VoiceEndpoint] {
        store.cloudDisabled ? [] : modeSet.endpoints.filter { $0.endpointAddress?.isOnThisMac == false }
    }

    private var refineField: some View {
        let kinds: [RefineKind] = store.cloudDisabled ? [.none, .local] : [.none, .local, .cloud]
        return field(voiceText("Improving the text"), detail: refineDetail) {
            PKSegmented(
                items: kinds.map { kind in
                    switch kind {
                    case .none: PKSegmented<RefineKind>.Item(value: .none, label: voiceText("No LLM"))
                    case .local: PKSegmented<RefineKind>.Item(value: .local, label: voiceText("On this Mac"))
                    case .cloud: PKSegmented<RefineKind>.Item(value: .cloud, label: voiceText("In the cloud"))
                    }
                },
                selection: Binding(get: { kind }, set: { choose($0) }), mini: true,
                disabled: cloudEndpoints.contains(where: store.isUsable) ? [] : [.cloud])
            if let refine = mode.refine {
                HStack(spacing: 8) {
                    Picker(selection: Binding(get: { refine.endpoint }, set: { id in
                        update {
                            $0.refine?.endpoint = id
                            if let preset = modeSet.endpoint(id)?.preset { $0.refine?.model = preset.suggestedModel }
                        }
                        store.askConsentIfNeeded(mode: mode.id, endpoint: id)
                    })) {
                        ForEach(kind == .cloud ? cloudEndpoints : localEndpoints) { endpoint in
                            Text(verbatim: endpoint.name).tag(endpoint.id).selectionDisabled(!store.isUsable(endpoint))
                        }
                    } label: { voiceText("Server") }
                        .labelsHidden()
                        .frame(width: 150)
                    TextField(text: Binding(get: { refine.model }, set: { model in
                        update { $0.refine?.model = model.trimmingCharacters(in: .whitespaces) }
                    }), prompt: Text(verbatim: "qwen2.5:7b")) { voiceText("Model") }
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
            }
        }
    }

    private var refineDetail: Text {
        switch kind {
        case .none:
            if BuiltInMode(rawValue: mode.id)?.wantsLanguageModel == true {
                return voiceText("Choose where the LLM works. Until then the text goes in unchanged.")
            }
            return voiceText("The text goes in as recognized. Only the dictionary and the text rules work.")
        case .local:
            let name = mode.refine.flatMap { modeSet.endpoint($0.endpoint)?.name } ?? "Ollama"
            return voiceText("\(name) on this Mac: the text does not leave it.")
        case .cloud:
            let endpoint = mode.refine.flatMap { modeSet.endpoint($0.endpoint) }
            return voiceText("\(endpoint?.name ?? "") by your key: the text goes to \(endpoint?.endpointAddress?.displayHost ?? "").")
        }
    }

    private func choose(_ kind: RefineKind) {
        guard kind != self.kind else { return }
        let pool = kind == .cloud ? cloudEndpoints : localEndpoints
        guard kind != .none, let endpoint = pool.first(where: store.isUsable) ?? pool.first else {
            update { $0.refine = nil }
            return
        }
        let builtIn = BuiltInMode(rawValue: mode.id).flatMap { VoiceModesStore.localized($0).prompt }
        let text = prompt.isEmpty ? builtIn ?? voiceString("Fix recognition errors. Do not change the meaning.") : prompt
        prompt = text
        update {
            $0.refine = RefineConfig(endpoint: endpoint.id, model: endpoint.preset?.suggestedModel ?? "", prompt: text)
        }
        if kind == .cloud { store.askConsentIfNeeded(mode: mode.id, endpoint: endpoint.id) }
    }

    private var promptField: some View {
        field(voiceText("What to do with the text")) {
            TextEditor(text: promptState.projectedValue)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 74)
                .background(RoundedRectangle(cornerRadius: PK.Radius.field).fill(Color.pkPlate))
                .overlay(RoundedRectangle(cornerRadius: PK.Radius.field).strokeBorder(Color.pkRule))
                .onChange(of: prompt) { update { $0.refine?.prompt = prompt } }
            HStack(spacing: 4) {
                ForEach(["{{text}}", "{{selection}}", "{{app}}", "{{site}}"], id: \.self) { variable in
                    Text(verbatim: variable)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.pkInk2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.pkWash))
                }
            }
        }
    }

    private var contextField: some View {
        field(voiceText("What else the LLM sees")) {
            VStack(alignment: .leading, spacing: 6) {
                check(\.selection) { voiceText("Selected text") }
                check(\.app) {
                    HStack(spacing: 6) {
                        voiceText("The app’s name")
                        voiceText("for example, Telegram").foregroundStyle(Color.pkInk3)
                    }
                }
                check(\.site) {
                    HStack(spacing: 6) {
                        voiceText("The site’s address")
                        voiceText("only the domain").foregroundStyle(Color.pkInk3)
                    }
                }
            }
        }
    }

    private func check<Label: View>(_ key: WritableKeyPath<ModeContext, Bool>, @ViewBuilder label: () -> Label)
        -> some View
    {
        Toggle(isOn: Binding(get: { mode.context[keyPath: key] }, set: { on in
            update { $0.context[keyPath: key] = on }
            if on, kind == .cloud, let endpoint = mode.refine?.endpoint {
                store.askConsentIfNeeded(mode: mode.id, endpoint: endpoint)
            }
        })) { label() }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
    }

    // MARK: Output

    private var outputField: some View {
        field(voiceText("Where the text goes"), detail: outputDetail) {
            PKSegmented(
                items: [
                    .init(value: ModeOutput.paste, label: voiceText("Paste")),
                    .init(value: ModeOutput.copy, label: voiceText("To the clipboard")),
                    .init(value: ModeOutput.pasteAndEnter, label: voiceText("Paste and Enter")),
                ],
                selection: Binding(get: { mode.output }, set: { output in update { $0.output = output } }),
                mini: true, disabled: mode.allowsEnter ? [] : [.pasteAndEnter])
        }
    }

    private var outputDetail: Text? {
        if mode.refine != nil {
            return voiceText("No Enter with an LLM: the model could write a command, and Enter would run it.")
        }
        if mode.rules.singleLine {
            return voiceText("In a terminal Perekey never presses Enter and takes out line breaks.")
        }
        return nil
    }

    // MARK: Bindings

    private var bindingsField: some View {
        field(voiceText("Where it turns on by itself")) {
            FlowLayout(spacing: 6) {
                if mode.bindings.isEmpty {
                    chip { voiceText("Nowhere: from the menu only").foregroundStyle(Color.pkInk2) }
                }
                ForEach(mode.bindings, id: \.self) { binding in
                    chip {
                        HStack(spacing: 5) {
                            switch binding {
                            case let .app(id):
                                if let icon = ModeBindingName.icon(id) {
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                }
                            case .site:
                                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(Color.pkInk2)
                            }
                            Text(verbatim: ModeBindingName.short(binding))
                            Button {
                                update { $0.bindings.removeAll { $0 == binding } }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.pkInk3)
                            .accessibilityLabel(voiceText("Remove"))
                        }
                    }
                }
                Button {
                    picker = AppPickerModel()
                    showPicker = true
                } label: {
                    chip { voiceText("Add app").foregroundStyle(Color.pkIndigoInk).fontWeight(.semibold) }
                }
                .buttonStyle(.plain)
                .popover(isPresented: showPickerState.projectedValue, arrowEdge: .bottom) {
                    if let picker {
                        AppPickerView(model: picker, existing: Set(mode.bindings.compactMap {
                            if case let .app(id) = $0 { id } else { nil }
                        })) { app in
                            store.update { $0.bind(.app(app.bundleID), to: mode.id) }
                            showPicker = false
                        }
                    }
                }
                Button { showSite = true } label: {
                    chip { voiceText("Add site").foregroundStyle(Color.pkIndigoInk).fontWeight(.semibold) }
                }
                .buttonStyle(.plain)
                .popover(isPresented: showSiteState.projectedValue, arrowEdge: .bottom) { sitePopover }
            }
        }
    }

    private var sitePopover: some View {
        let host = SiteHost.normalized(site)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(text: siteState.projectedValue, prompt: Text(verbatim: "mail.google.com")) { voiceText("Site") }
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { addSite(host) }
            HStack {
                Spacer()
                Button { addSite(host) } label: { voiceText("Add") }
                    .buttonStyle(.pkPrimary)
                    .disabled(host == nil)
            }
        }
        .padding(12)
    }

    private func addSite(_ host: String?) {
        guard let host else { return }
        store.update { $0.bind(.site(host), to: mode.id) }
        site = ""
        showSite = false
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.pkPlate))
            .overlay(Capsule().strokeBorder(Color.pkRule, lineWidth: 0.5))
    }
}

// MARK: - Servers and keys

private struct EndpointsGroup: View {
    let store: VoiceModesStore
    private let keyForState = State<String?>(initialValue: nil)
    private var keyFor: String? {
        get { keyForState.wrappedValue }
        nonmutating set { keyForState.wrappedValue = newValue }
    }
    private let keyState = State<String>(initialValue: "")
    private var key: String {
        get { keyState.wrappedValue }
        nonmutating set { keyState.wrappedValue = newValue }
    }
    private let addingState = State<Bool>(initialValue: false)
    private var adding: Bool {
        get { addingState.wrappedValue }
        nonmutating set { addingState.wrappedValue = newValue }
    }
    private let newNameState = State<String>(initialValue: "")
    private var newName: String {
        get { newNameState.wrappedValue }
        nonmutating set { newNameState.wrappedValue = newValue }
    }
    private let newAddressState = State<String>(initialValue: "")
    private var newAddress: String {
        get { newAddressState.wrappedValue }
        nonmutating set { newAddressState.wrappedValue = newValue }
    }

    var body: some View {
        PKGroup(header: voiceText("Where the LLM works")) {
            PKNote(store.cloudDisabled
                ? voiceText("Your administrator turned the cloud off: only servers on this Mac.")
                : voiceText("Keys are kept in the Keychain. Before the first request to the cloud Perekey asks and names what will go there."))
            ForEach(endpoints) { endpoint in
                PKDivider()
                row(endpoint)
            }
            PKDivider()
            PKRow(voiceText("Your address"),
                  detail: voiceText("Any OpenAI-compatible server: LM Studio, OpenRouter, Mistral, your own")) {
                Button { adding = true } label: { voiceText("Add") }
                    .buttonStyle(.pkSmall)
                    .popover(isPresented: addingState.projectedValue, arrowEdge: .bottom) { addPopover }
            }
        }
    }

    private var endpoints: [VoiceEndpoint] {
        store.modes.endpoints.filter { !store.cloudDisabled || $0.endpointAddress?.isOnThisMac == true }
    }

    private func row(_ endpoint: VoiceEndpoint) -> some View {
        let address = endpoint.endpointAddress
        let local = address?.isOnThisMac == true
        return PKRow(Text(verbatim: endpoint.name), detail: Text(verbatim: detail(endpoint))) {
            HStack(spacing: 8) {
                if local {
                    PKTag(text: voiceText("on this Mac"))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "cloud").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
                        PKTag(text: voiceText("cloud"))
                    }
                    .foregroundStyle(Color.pkIndigoInk)
                }
                if !local || endpoint.preset == nil {
                    Button {
                        key = ""
                        keyFor = endpoint.id
                    } label: {
                        store.hasKey(endpoint.id) ? voiceText("Change key") : voiceText("Add key")
                    }
                    .buttonStyle(store.hasKey(endpoint.id) || !endpoint.needsKey ? .pkSmall
                        : PKButtonStyle(kind: .primary, small: true))
                    .popover(isPresented: Binding(get: { keyFor == endpoint.id }, set: { if !$0 { keyFor = nil } }),
                             arrowEdge: .bottom) { keyPopover(endpoint) }
                }
                if let origin = address?.origin, !(store.modes.consents[origin] ?? []).isEmpty {
                    Button { store.update { $0.revokeConsent(endpoint: endpoint.id) } } label: {
                        voiceText("Revoke access")
                    }
                    .buttonStyle(.pkLink)
                    .help(voiceText("Perekey asks again before the next request there"))
                }
                if endpoint.preset == nil {
                    Button {
                        store.setKey("", for: endpoint.id)
                        store.update { set in
                            set.endpoints.removeAll { $0.id == endpoint.id }
                            for index in set.modes.indices where set.modes[index].refine?.endpoint == endpoint.id {
                                set.modes[index].refine = nil
                            }
                        }
                    } label: { voiceText("Remove") }
                        .buttonStyle(.pkLink)
                }
            }
        }
    }

    private func detail(_ endpoint: VoiceEndpoint) -> String {
        guard let address = endpoint.endpointAddress else { return voiceString("The address is not usable") }
        if address.isOnThisMac { return voiceString("\(address.displayHost) · does not go to the network") }
        if store.hasKey(endpoint.id) { return voiceString("\(address.displayHost) · key in the Keychain") }
        return endpoint.needsKey ? voiceString("\(address.displayHost) · no key") : address.displayHost
    }

    private func keyPopover(_ endpoint: VoiceEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            voiceText("API key for \(endpoint.name)").font(PK.Font.bodyStrong)
            SecureField(text: keyState.projectedValue, prompt: Text(verbatim: "sk-…")) { voiceText("Key") }
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { saveKey(endpoint) }
            voiceText("It is kept in the Keychain and goes only to this server.")
                .font(PK.Font.caption).foregroundStyle(Color.pkInk2)
            HStack {
                if store.hasKey(endpoint.id) {
                    Button {
                        store.setKey("", for: endpoint.id)
                        keyFor = nil
                    } label: { voiceText("Remove key") }
                        .buttonStyle(.pkLink)
                }
                Spacer()
                Button { saveKey(endpoint) } label: { voiceText("Save") }
                    .buttonStyle(.pkPrimary)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func saveKey(_ endpoint: VoiceEndpoint) {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.setKey(key, for: endpoint.id)
        key = ""
        keyFor = nil
    }

    private var addPopover: some View {
        let address = EndpointAddress(newAddress)
        return VStack(alignment: .leading, spacing: 8) {
            TextField(text: newNameState.projectedValue, prompt: Text(verbatim: "LM Studio")) { voiceText("Name") }
                .textFieldStyle(.roundedBorder)
            TextField(text: newAddressState.projectedValue, prompt: Text(verbatim: "https://openrouter.ai/api/v1")) { voiceText("Address") }
                .textFieldStyle(.roundedBorder)
            voiceText("https, or http on this Mac and in the local network. The address ends where /chat/completions would begin.")
                .font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button {
                    guard let address else { return }
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    store.update { $0.addEndpoint(name: name.isEmpty ? address.displayHost : name, address: newAddress) }
                    newName = ""
                    newAddress = ""
                    adding = false
                } label: { voiceText("Add") }
                    .buttonStyle(.pkPrimary)
                    .disabled(address == nil)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// Lays chips out in rows, wrapping at the width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
#endif

#if PEREKEY_VOICE
/// "Сказали → станет" for a built-in mode, from the mockup.
struct ModeSample {
    let said: String
    let result: String

    static func of(_ mode: BuiltInMode) -> ModeSample? {
        switch mode {
        case .asSaid:
            ModeSample(said: voiceString("uh let's call tomorrow after lunch"),
                       result: voiceString("Let's call tomorrow after lunch."))
        case .clean:
            ModeSample(said: voiceString("so we like we'll call tomorrow well after lunch"),
                       result: voiceString("We'll call tomorrow after lunch."))
        case .message:
            ModeSample(said: voiceString("listen I'll look at the pull request tonight and get back"),
                       result: voiceString("I'll look at the pull request tonight and get back"))
        case .mail:
            ModeSample(said: voiceString("hi anna sending the report have a look by friday"),
                       result: voiceString("Hello Anna, I am sending the report. Please have a look by Friday."))
        case .terminal:
            ModeSample(said: "git pull origin main", result: "git pull origin main")
        case .english:
            ModeSample(said: voiceString("let's move the call to monday"), result: "Let’s move the call to Monday.")
        }
    }
}
#endif
