// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

/// What the caret hint says.
enum HintContent: Equatable {
    case corrected(original: String, replacement: String)
    case learned(word: String)
}

/// State the hint view draws. The controller changes `visible` inside
/// `withAnimation`, so the enter and the exit run as DESIGN.md says.
@MainActor @Observable
final class HintModel {
    var content: HintContent
    var visible: Bool
    /// Frame of the button in the hosting view, top-left origin; the panel
    /// takes mouse events only there.
    var buttonFrame: CGRect = .zero
    /// Called after `buttonFrame` changed.
    @ObservationIgnored var onButtonFrameChange: (() -> Void)?

    init(content: HintContent, visible: Bool = false) {
        self.content = content
        self.visible = visible
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
}

/// Floating popover (radius 13): struck-out original, new word with the
/// fixed-word underline and an «Undo» chip; or «Remembered “word” · Forget».
struct HintView: View {
    let model: HintModel
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 13, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            switch model.content {
            case let .corrected(original, replacement):
                correction(original: original, replacement: replacement)
                chip(Text("Undo"), keycap: "⌫")
            case let .learned(word):
                Text("Remembered “\(word)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.pkInk)
                chip(Text("Forget"), keycap: nil)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .fixedSize()
        .pkGlass(in: shape)
        .background(shape.fill(Color.pkPlate.opacity(scheme == .dark ? 0.55 : 0.6)))
        .overlay(shape.strokeBorder(Color.pkRule, lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.16), radius: 14, x: 0, y: 8)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        .padding(HintMetrics.shadowInset)
        .coordinateSpace(name: "hint")
        .onPreferenceChange(ButtonFrameKey.self) {
            model.buttonFrame = $0
            model.onButtonFrameChange?()
        }
        // translateY(4) scale(.96) -> rest; the origin sits at the left edge, bottom.
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.96, anchor: UnitPoint(x: 0.1, y: 0.9))
        .offset(y: model.visible ? 0 : 4)
        .fixedSize()
    }

    private func correction(original: String, replacement: String) -> some View {
        HStack(spacing: 6) {
            Text(struck(original))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.pkInk3)
            Text(verbatim: "→").font(.system(size: 12.5)).foregroundStyle(Color.pkInk2)
            Text(replacement)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.pkInk)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.pkIndigo.opacity(0.5)).frame(height: 1.5).offset(y: 3)
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
