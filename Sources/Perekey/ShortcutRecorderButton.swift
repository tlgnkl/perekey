// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import SwiftUI

/// Shows the shortcut of one action as keycaps on a 28pt plate. A click starts
/// recording: the plate gets a 1.5pt indigo ring and an Indigo Mist shimmer.
struct ShortcutRecorderButton: View {
    let action: HotkeyAction
    let store: SettingsStore
    let recording: ShortcutRecording

    var body: some View {
        let isRecording = recording.action == action
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording.toggle(action) } label: {
                Group {
                    if isRecording {
                        Text("Press a shortcut…").font(PK.Font.caption).foregroundStyle(Color.pkIndigoInk)
                    } else if let trigger = store.settings.trigger(for: action) {
                        HStack(spacing: 4) {
                            ForEach(Array(TriggerText.keycaps(of: trigger).enumerated()), id: \.offset) { _, cap in
                                PKKeycap(text: cap)
                            }
                        }
                    } else {
                        Text("Record").font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                    }
                }
                .padding(.horizontal, 6)
                .frame(minWidth: 96, minHeight: 28)
                .background(RecorderPlate(recording: isRecording))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pkAnimation(PK.Motion.easeOut(0.2), value: isRecording)
            if isRecording, let hint = recording.hint {
                Text(hint).font(PK.Font.caption).foregroundStyle(Color.pkWarn)
            }
        }
    }
}

private struct RecorderPlate: View {
    let recording: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PK.Radius.popup + 2, style: .continuous)
        shape.fill(recording ? Color.pkPlate : Color.pkWash)
            .overlay {
                if recording {
                    if reduceMotion {
                        shape.fill(Color.pkMist)
                    } else {
                        TimelineView(.animation) { timeline in
                            GeometryReader { proxy in
                                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                                LinearGradient(colors: [.clear, Color.pkMist, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: proxy.size.width * 0.6)
                                    .offset(x: -proxy.size.width * 0.6 + phase * proxy.size.width * 1.6)
                            }
                        }
                        .clipShape(shape)
                    }
                }
            }
            .overlay(shape.strokeBorder(recording ? Color.pkIndigo : Color.pkRule, lineWidth: recording ? 1.5 : 0.5))
            .background(shape.fill(Color.pkMist).padding(-3).opacity(recording ? 1 : 0))
    }
}
