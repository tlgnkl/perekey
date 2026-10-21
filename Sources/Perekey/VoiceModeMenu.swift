// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_VOICE
import PerekeyCore
import PerekeyInput
import PerekeyVoiceCore
import SwiftUI

/// The voice mode in the menu: "Auto" picks it by the site and the app; any
/// other choice holds everywhere until "Auto" again.
@MainActor
struct VoiceModeMenu {
    let store: VoiceModesStore
    /// Voice is on: the row shows only then.
    let isOn: @MainActor () -> Bool

    /// The mode "Auto" gives for what is in front now.
    func automatic(_ appModes: AppModeController) -> VoiceMode? {
        var set = store.modes
        set.pinnedModeID = nil
        let app = appModes.frontmost?.bundleID
        let host = app.map(SiteObserver.browserBundleIDs.contains) == true ? appModes.frontHost : nil
        return ModeResolver.resolve(bundleID: app, host: host, in: set)?.mode
    }

    /// Steps through "Auto" and the modes, for the keyboard.
    func step(_ delta: Int) {
        let ids: [String?] = [nil] + store.modes.modes.map(\.id)
        let index = ids.firstIndex { $0 == store.modes.pinnedModeID } ?? 0
        let next = ids[(index + delta + ids.count) % ids.count]
        store.update { $0.pinnedModeID = next }
    }
}

struct VoiceModeMenuRow: View {
    let menu: VoiceModeMenu
    let appModes: AppModeController
    let lit: Bool

    private var store: VoiceModesStore { menu.store }

    var body: some View {
        let pinned = store.modes.mode(store.modes.pinnedModeID)
        let automatic = menu.automatic(appModes)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                voiceText("Voice mode").font(PK.Font.body).foregroundStyle(Color.pkInk)
                Group {
                    if pinned != nil {
                        voiceText("Everywhere until Auto")
                    } else if let automatic {
                        voiceText("Auto: \(automatic.name)")
                    }
                }
                .font(PK.Font.caption).foregroundStyle(Color.pkInk2).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                Button { store.update { $0.pinnedModeID = nil } } label: {
                    if pinned == nil { Label { voiceText("Auto") } icon: { Image(systemName: "checkmark") } }
                    else { voiceText("Auto") }
                }
                Divider()
                ForEach(store.modes.modes) { mode in
                    Button { store.update { $0.pinnedModeID = mode.id } } label: {
                        if pinned?.id == mode.id {
                            Label { Text(verbatim: mode.name) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(verbatim: mode.name)
                        }
                    }
                }
            } label: {
                if let pinned { Text(verbatim: pinned.name) } else { voiceText("Auto") }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isLocked)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.pkIndigo, lineWidth: 1.5)
                .opacity(lit ? 1 : 0))
    }
}
#endif
