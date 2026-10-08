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
        .switchLayout, .convertLastWord, .toggleAutoswitch, .undoLastCorrection, .selectLanguage("en"),
        .selectLanguage("ru"), .changeCase, .transliterate, .pastePlain,
    ]

    var body: some View {
        PKPane(title: Text("Shortcuts")) {
            Text("Pick a set by habit or record your own. A shortcut of modifiers alone fires when you release the keys.")
                .font(PK.Font.body)
                .foregroundStyle(Color.pkInk2)
                .fixedSize(horizontal: false, vertical: true)
            presetSection
            actionsSection
            capsLockSection
        }
    }

    private var presetSection: some View {
        PKGroup(header: Text("Preset")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                    PresetChip(title: preset.title, note: preset.note, isSelected: store.settings.preset == preset) {
                        recording.stop()
                        store.update { $0.apply(preset) }
                    }
                }
            }
            .padding(PK.Space.md)
        }
    }

    private var actionsSection: some View {
        PKGroup {
            ForEach(Array(Self.actions.enumerated()), id: \.element) { index, action in
                if index > 0 { PKDivider() }
                PKRow(Text(verbatim: TriggerText.name(of: action)), detail: detail(of: action)) {
                    ShortcutRecorderButton(action: action, store: store, recording: recording)
                }
            }
            ForEach(recording.conflictTexts, id: \.self) { text in
                PKCallout(Text(text))
            }
        }
    }

    private func detail(of action: HotkeyAction) -> Text? {
        switch action {
        case .changeCase: Text("Press again to go lower, Title, UPPER.")
        case .transliterate: Text("Selection only: Cyrillic to Latin and back.")
        case .pastePlain: Text("Off until you record a key with modifiers, such as ⌃⌥V.")
        case .undoLastCorrection: Text("Backspace right after a correction does the same.")
        default: nil
        }
    }

    private var capsLockSection: some View {
        PKGroup(header: Text("Caps Lock")) {
            PKRow(Text("How to use Caps Lock")) {
                PKSegmented(items: [
                    .init(value: .untouched, label: Text("Don't touch")),
                    .init(value: .system, label: Text("Like macOS")),
                    .init(value: .instant, label: Text("Instant")),
                ], selection: capsLockBinding)
                .frame(width: 280)
            }

            switch store.settings.capsLock {
            case .untouched:
                EmptyView()
            case .system:
                PKDivider()
                PKRow(Text("Uses the macOS setting “Use Caps Lock to switch to and from ABC”. macOS adds a short delay.")) {
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.pkSecondary)
                }
            case .instant:
                PKDivider()
                PKNote(Text("Perekey remaps Caps Lock and gives it back when it quits."))
                if CapsLockRemapper.isKarabinerRunning {
                    PKCallout(Text("Karabiner-Elements is running. Its rules may override this."))
                }
            }
            if store.capsLockFailed {
                PKCallout(Text("macOS refused to change Caps Lock."), symbol: "xmark.octagon.fill", tone: .error)
            }
            if CapsLockRemapper.isRemapped {
                PKCalloutButton(Text("Restore Caps Lock"), symbol: "arrow.uturn.backward") { store.setCapsLock(.untouched) }
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
/// Selected: 2.5pt indigo ring with glow, plus a checkmark (a ring alone vanishes
/// for people who cannot tell the tint apart).
struct PresetChip: View {
    let title: String
    let note: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(PK.Font.bodyStrong).foregroundStyle(Color.pkInk)
                    Text(verbatim: note).font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.pkIndigo : Color.pkInk3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pkPlate, in: shape)
            .overlay(shape.strokeBorder(isSelected ? Color.pkIndigo : Color.pkRule, lineWidth: isSelected ? 2.5 : 0.5))
            .shadow(color: isSelected ? Color.pkGlow : .clear, radius: 7, y: 4)
            .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .pkAnimation(PK.Motion.spring, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Press scales to .95 (picker tiles) with the press curve.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .pkAnimation(PK.Motion.press, value: configuration.isPressed)
    }
}
