// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

/// What the caret hint says.
enum HintContent: Equatable {
    case corrected(original: String, replacement: String)
    /// The user's own retype: «привет · ⌥ — вернуть». `shortcut` is their real
    /// retype shortcut, nil if they have none. No button.
    case retyped(original: String, word: String, shortcut: String?)
    case learned(word: String)

    var hasButton: Bool {
        if case .retyped = self { false } else { true }
    }
}

/// State the hint view draws. The controller changes `visible` inside
/// `withAnimation`, so the enter and the exit run as DESIGN.md says.
@MainActor @Observable
final class HintModel {
    var content: HintContent
    var visible: Bool
    /// Where the bubble sits in the panel, top-left origin, shadow room not
    /// included. The panel is larger than the bubble while it moves to a new
    /// place; animating this is what makes the hint glide and resize. `nil`
    /// lays the bubble out by itself at the top left (snapshots).
    var bubble: CGRect?
    /// The glass strip correction of the changed word.
    let strip: GlassStripPlayer
    /// Frame of the button in the hosting view, top-left origin; the panel
    /// takes mouse events only there.
    var buttonFrame: CGRect = .zero
    /// The bubble is on its way to a new place; its button takes no clicks.
    var gliding = false
    /// Called after `buttonFrame` changed.
    @ObservationIgnored var onButtonFrameChange: (() -> Void)?

    init(content: HintContent, visible: Bool = false, bubble: CGRect? = nil, stripProgress: Double = 1,
         stripStyle: GlassStripStyle = .fix)
    {
        self.content = content
        self.visible = visible
        self.bubble = bubble
        strip = GlassStripPlayer(progress: stripProgress, style: stripStyle)
    }
}

private struct ButtonFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Room around the bubble for its shadow; the panel is this much larger.
enum HintMetrics {
    static let shadowInset: CGFloat = 18
    /// Longest word the hint prints; a retyped selection can be a paragraph.
    static let maxWord = 28

    static func shortened(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > maxWord || line.count < text.count ? String(line.prefix(maxWord - 1)) + "…" : line
    }
}

/// What the bubble holds, at its natural size. `HintView` frames it; the
/// controller measures a copy of it to know the size a new hint needs.
struct HintBubbleContent: View {
    let model: HintModel
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch model.content {
            case let .corrected(original, replacement):
                correction(original: original, replacement: replacement)
                chip(Text("Undo"), keycap: "⌫")
            case let .retyped(original, word, shortcut):
                retyped(original: original, word: word, shortcut: shortcut)
            case let .learned(word):
                Text("Remembered “\(word)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.pkInk)
                chip(Text("Forget"), keycap: nil)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, model.content.hasButton ? 6 : 12)
        .padding(.vertical, model.content.hasButton ? 6 : 9)
        .fixedSize()
    }

    private func slot(before: String, after: String) -> some View {
        GlassStripWord(before: before, after: after, progress: model.strip.progress, style: model.strip.style,
                       font: .system(size: 12.5, weight: .medium), color: .pkInk, beforeColor: .pkInk3, radius: 7)
    }

    private func correction(original: String, replacement: String) -> some View {
        HStack(spacing: 6) {
            Text(struck(original))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.pkInk3)
            Text(verbatim: "→").font(.system(size: 12.5)).foregroundStyle(Color.pkInk2)
            slot(before: original, after: replacement)
        }
        .accessibilityElement(children: .combine)
    }

    private func retyped(original: String, word: String, shortcut: String?) -> some View {
        HStack(spacing: 6) {
            slot(before: original, after: word)
            if let shortcut {
                Text(verbatim: "·").font(.system(size: 12.5)).foregroundStyle(Color.pkInk3)
                Text(verbatim: shortcut)
                    .font(PK.Font.keycap)
                    .foregroundStyle(Color.pkInk)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.keycapSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: PK.Radius.keycapSmall, style: .continuous)
                        .strokeBorder(Color.pkRule, lineWidth: 0.5))
                Text("— revert").font(.system(size: 12.5)).foregroundStyle(Color.pkInk2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func struck(_ text: String) -> AttributedString {
        var string = AttributedString(text)
        string.strikethroughStyle = .single
        string.strikethroughColor = NSColor(Color.pkIndigo.opacity(0.55))
        return string
    }

    private func chip(_ label: Text, keycap: String?) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if keycap != nil {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .semibold))
                }
                label.font(.system(size: 12.5, weight: .semibold))
                if let keycap { Text(keycap).font(.system(size: 12.5, weight: .semibold)).opacity(0.6) }
            }
            .foregroundStyle(Color.pkIndigoInk)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.pkMist))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ButtonFrameKey.self, value: proxy.frame(in: .named("hint")))
        })
    }
}

/// Floating popover (radius 13): struck-out original, new word under the glass
/// strip correction with the fixed-word underline and an «Undo» chip; the same
/// word with the retype shortcut after a manual retype; or «Remembered “word”
/// · Forget».
struct HintView: View {
    let model: HintModel
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 13, style: .continuous) }

    var body: some View {
        Group {
            if let rect = model.bubble {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    bubble(size: rect.size).offset(x: rect.minX, y: rect.minY)
                }
            } else {
                bubble(size: nil).padding(HintMetrics.shadowInset)
            }
        }
        .coordinateSpace(name: "hint")
        .onPreferenceChange(ButtonFrameKey.self) {
            model.buttonFrame = $0
            model.onButtonFrameChange?()
        }
    }

    private func bubble(size: CGSize?) -> some View {
        let dark = scheme == .dark
        return HintBubbleContent(model: model, action: action)
            .frame(width: size?.width, height: size?.height, alignment: .leading)
            .clipShape(shape)
            .pkGlass(in: shape)
            .background(shape.fill(Color.pkPlate.opacity(dark ? 0.55 : 0.6)))
            // Rim and glow: the light rim, the hairline, and an indigo under-glow.
            .overlay(shape.strokeBorder(.white.opacity(dark ? 0.16 : 0.7), lineWidth: 0.5))
            .overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5))
            .shadow(color: Color.pkGlow, radius: 14, x: 0, y: 8)
            .shadow(color: Color.pkIndigo.opacity(dark ? 0.3 : 0.16), radius: 2, x: 0, y: 1)
            // translateY(4) scale(.96) -> rest; the origin sits at the left edge, bottom.
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.visible ? 1 : 0.96, anchor: UnitPoint(x: 0.1, y: 0.9))
            .offset(y: model.visible ? 0 : 4)
    }
}
