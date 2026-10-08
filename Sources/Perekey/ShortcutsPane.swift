// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import PerekeyCore
import PerekeyInput
import SwiftUI

/// Settings → Shortcuts: preset, one recorder per action, Caps Lock.
struct ShortcutsPane: View {
    let store: SettingsStore
    let recording: ShortcutRecording

    private static let actions: [HotkeyAction] = [
        .switchLayout, .convertLastWord, .toggleAutoswitch, .selectLanguage("en"), .selectLanguage("ru"),
    ]

    var body: some View {
        Form {
            Section {
                Text("Pick a set by habit or record your own. A shortcut of modifiers alone fires when you release the keys.")
                    .foregroundStyle(.secondary)
            }
            presetSection
            actionsSection
            capsLockSection
        }
        .formStyle(.grouped)
    }

    private var presetSection: some View {
        Section("Preset") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                    PresetChip(title: preset.title, note: preset.note, isSelected: store.settings.preset == preset) {
                        recording.stop()
                        store.update { $0.apply(preset) }
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(Self.actions, id: \.self) { action in
                LabeledContent {
                    ShortcutRecorderButton(action: action, store: store, recording: recording)
                } label: {
                    Text(verbatim: TriggerText.name(of: action))
                }
            }
            ForEach(recording.conflictTexts, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var capsLockSection: some View {
        Section("Caps Lock") {
            Picker("How to use Caps Lock", selection: capsLockBinding) {
                Text("Don't touch").tag(CapsLockMode.untouched)
                Text("Like macOS").tag(CapsLockMode.system)
                Text("Instant").tag(CapsLockMode.instant)
            }
            .pickerStyle(.segmented)

            switch store.settings.capsLock {
            case .untouched:
                EmptyView()
            case .system:
                Text("Uses the macOS setting “Use Caps Lock to switch to and from ABC”. macOS adds a short delay.")
                    .foregroundStyle(.secondary)
                Button("Open Keyboard Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .instant:
                Text("Perekey remaps Caps Lock and gives it back when it quits.")
                    .foregroundStyle(.secondary)
                if CapsLockRemapper.isKarabinerRunning {
                    Label("Karabiner-Elements is running. Its rules may override this.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if store.capsLockFailed {
                Label("macOS refused to change Caps Lock.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if CapsLockRemapper.isRemapped {
                Button("Restore Caps Lock") { store.setCapsLock(.untouched) }
            }
        }
    }

    private var capsLockBinding: Binding<CapsLockMode> {
        Binding(
            get: { store.settings.capsLock },
            set: { mode in
                if mode == .instant, !confirmReplacingForeignRemap() { return }
                store.setCapsLock(mode)
            }
        )
    }

    /// Instant mode replaces someone else's Caps Lock remap: ask first.
    private func confirmReplacingForeignRemap() -> Bool {
        guard CapsLockRemapper.foreignCapsLockRemap != nil else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Replace the existing Caps Lock remapping?")
        alert.informativeText = String(localized: "Caps Lock is already remapped on this Mac. Instant mode will replace that remapping.")
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// One choice in a preset grid. Onboarding reuses it, with an extra Caps Lock choice.
struct PresetChip: View {
    let title: String
    let note: String
    let isSelected: Bool
    let action: () -> Void

    // The selection is a ring and a checkmark, not a tint: an inactive window
    // draws every prominent button grey, and the choice would vanish with focus.
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).fontWeight(.semibold)
                    Text(verbatim: note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
