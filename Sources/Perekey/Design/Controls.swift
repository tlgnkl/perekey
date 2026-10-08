// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Switch

/// 38x22. Wash Deep off, Solid Indigo Fill on, a white knob on a spring.
struct PKSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: .leading) {
                    Capsule().fill(on ? Color.pkIndigoFill : Color.pkWashDeep)
                    Capsule().strokeBorder(Color.pkRule, lineWidth: on ? 0 : 0.5)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                        .frame(width: 18, height: 18)
                        .offset(x: on ? 18 : 2)
                }
                .frame(width: 38, height: 22)
                .pkAnimation(PK.Motion.spring, value: on)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.5)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }
    }
}

extension ToggleStyle where Self == PKSwitchStyle {
    static var pkSwitch: PKSwitchStyle { PKSwitchStyle() }
}

// MARK: - Buttons

/// Pill buttons, 30pt (small 24pt). Primary is Solid Indigo Fill with white
/// text; secondary is Wash Deep. Press scales to .97.
struct PKButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var small = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let primary = kind == .primary && enabled
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Color.white : (kind == .primary ? Color.pkInk2 : Color.pkInk))
            .padding(.horizontal, small ? 11 : 16)
            .frame(height: small ? 24 : 30)
            .background(
                Capsule().fill(primary ? Color.pkIndigoFill : Color.pkWashDeep)
            )
            .overlay(alignment: .top) {
                if primary {
                    Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                }
            }
            .shadow(color: primary ? Color.pkGlow : .clear, radius: 7, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .pkAnimation(PK.Motion.press, value: configuration.isPressed)
            .opacity(enabled || kind == .primary ? 1 : 0.5)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PKButtonStyle {
    static var pkPrimary: PKButtonStyle { PKButtonStyle(kind: .primary) }
    static var pkSecondary: PKButtonStyle { PKButtonStyle(kind: .secondary) }
    static var pkSmall: PKButtonStyle { PKButtonStyle(kind: .secondary, small: true) }
}

/// A text-only action in Indigo Ink, for "Forget", "Remove" and similar.
struct PKLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.pkIndigoInk)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(configuration.isPressed ? Color.pkMist : Color.clear))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PKLinkButtonStyle {
    static var pkLink: PKLinkButtonStyle { PKLinkButtonStyle() }
}

// MARK: - Segmented control

/// Wash track, 2pt padding, radius 10. The thumb is a glass strip that springs
/// between segments.
struct PKSegmented<Value: Hashable>: View {
    struct Item {
        let value: Value
        let label: Text
    }

    let items: [Item]
    @Binding var selection: Value
    var mini = false

    @Namespace private var thumbSpace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    item.label
                        .font(.system(size: mini ? 12 : 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.pkInk : Color.pkInk2)
                        .lineLimit(1)
                        .fixedSize(horizontal: mini, vertical: false)
                        .padding(.horizontal, mini ? 10 : 12)
                        .frame(maxWidth: mini ? nil : .infinity, minHeight: mini ? 22 : 26)
                        .background {
                            if selected {
                                Color.clear
                                    .glassStrip(in: RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
                                    .matchedGeometryEffect(id: "thumb", in: thumbSpace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.pkWash, in: RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PK.Radius.segment, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
        .pkAnimation(PK.Motion.thumbSpring, value: selection)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Keycap, tag, pills

/// A key as a Solid Plate with the physical lower edge. Keycap-only shadow.
struct PKKeycap: View {
    let text: String
    var big = false

    var body: some View {
        let isWord = text.count > 1 && text != "fn"
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .font(isWord ? .system(size: 11.5, weight: .semibold) : PK.Font.keycap)
            .foregroundStyle(isWord ? Color.pkInk2 : Color.pkInk)
            .padding(.horizontal, 7)
            .frame(minWidth: big ? 44 : 24, minHeight: big ? 40 : 24)
            .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.popup, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PK.Radius.popup, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
            .background(
                RoundedRectangle(cornerRadius: PK.Radius.popup, style: .continuous)
                    .fill(Color.pkWashDeep)
                    .offset(y: big ? 2.5 : 1.5)
            )
            .padding(.bottom, big ? 2.5 : 1.5)
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// 11pt 600 Indigo Ink on Indigo Mist, radius 6.
struct PKTag: View {
    let text: Text

    var body: some View {
        text
            .font(PK.Font.tag)
            .foregroundStyle(Color.pkIndigoInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.pkMist, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 24pt status pills: waiting, denied, granted.
struct PKStatusPill: View {
    enum Kind { case waiting, denied, granted }
    let kind: Kind
    let text: Text
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            switch kind {
            case .waiting: ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            case .denied: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .bold))
            case .granted: Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
            }
            text.font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(background))
        .overlay { if kind == .waiting, !reduceMotion { PillShimmer() } }
    }

    private var foreground: Color {
        switch kind {
        case .waiting: .pkInk2
        case .denied: .pkWarn
        case .granted: .pkOK
        }
    }

    private var background: Color {
        switch kind {
        case .waiting: .pkWash
        case .denied: .pkWarnSoft
        case .granted: .pkOKSoft
        }
    }
}

/// A soft band that sweeps across a waiting pill. It exists only while the
/// pill waits, so nothing animates once access is granted.
private struct PillShimmer: View {
    private let sweep = State(initialValue: false)

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.5)
                .offset(x: sweep.wrappedValue ? proxy.size.width : -proxy.size.width * 0.5)
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep.wrappedValue = true } }
    }
}

/// The example beside a correction's switch, 30pt on Plate with a hairline:
/// on, "ПРивет → Привет" with the typed text struck through in Indigo;
/// off, only the typed text, as it stays. Turning the switch on replays the
/// glass strip correction inside the chip, turning it off plays the undo (rose
/// glow) back to the typed text, and hovering an "on" chip replays it. At rest
/// nothing runs.
struct PKExampleChip: View {
    let from: String
    let to: String
    let isOn: Bool

    /// Whether the typed text and the arrow come in or go out with the strip.
    private enum Prefix { case steady, appearing, vanishing }

    /// What the chip shows now. It follows `isOn` together with the player, so
    /// the new words never flash before the animation starts.
    private let shownState: State<Bool>
    private let prefixState: State<Prefix>
    private let playerState: State<GlassStripPlayer>
    private var shown: Bool { shownState.wrappedValue }
    private var player: GlassStripPlayer { playerState.wrappedValue }

    /// `phase` freezes the chip mid-correction, for snapshots.
    init(from: String, to: String, isOn: Bool, phase: (progress: Double, style: GlassStripStyle)? = nil) {
        self.from = from
        self.to = to
        self.isOn = isOn
        shownState = State(initialValue: isOn)
        playerState = State(initialValue: GlassStripPlayer(progress: phase?.progress ?? 1, style: phase?.style ?? .fix))
        var prefix = Prefix.steady
        if let phase, phase.progress < 1 {
            prefix = phase.style == .undo ? .vanishing : (isOn ? .steady : .appearing)
        }
        prefixState = State(initialValue: prefix)
    }

    /// How much of the struck original and the arrow shows, 0 ... 1. It
    /// follows the strip's progress so both play as one.
    private var prefixShare: Double {
        switch prefixState.wrappedValue {
        case .steady: shown ? 1 : 0
        case .appearing: player.progress
        case .vanishing: 1 - player.progress
        }
    }

    private var prefixWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13.5)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        return ceil(width(from) + width("→")) + 14
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: from).strikethrough(color: Color.pkIndigo.opacity(0.55)).foregroundStyle(Color.pkInk3)
                Text(verbatim: "→").foregroundStyle(Color.pkInk3).padding(.horizontal, 7)
            }
            .fixedSize()
            .frame(width: prefixWidth * prefixShare, alignment: .leading)
            .clipped()
            .opacity(prefixShare)
            GlassStripWord(before: shown ? from : to, after: shown ? to : from, progress: player.progress,
                           style: player.style, font: .system(size: 13.5), color: shown ? .pkInk : .pkInk2,
                           beforeColor: shown ? .pkInk2 : .pkInk, underline: shown, radius: 7)
        }
        .font(.system(size: 13.5))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(minWidth: 158, minHeight: 30, maxHeight: 30)
        .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.pkRule, lineWidth: 0.5))
        .onChange(of: isOn) { _, on in
            shownState.wrappedValue = on
            prefixState.wrappedValue = on ? .appearing : .vanishing
            player.play(on ? .fix : .undo)
        }
        .onHover { inside in
            if inside, shown {
                prefixState.wrappedValue = .steady
                player.play(.fix)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: isOn ? "\(from) → \(to)" : from))
    }
}

/// A 28pt chip on Wash; the selected one becomes a glass strip with 600 text.
struct PKChip: View {
    let text: Text
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            text
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.pkInk : Color.pkInk2)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    if selected {
                        Color.clear.glassStrip(in: Capsule())
                    } else {
                        Capsule().fill(Color.pkWash)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Settings pane, group, row

/// A pane: 22pt title, then groups 16pt apart.
struct PKPane<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                title
                    .font(PK.Font.title)
                    .tracking(-0.33)
                    .foregroundStyle(Color.pkInk)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20)
            .padding(.horizontal, PK.Space.pane)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
    }
}

/// A heading and a card of rows.
struct PKGroup<Content: View>: View {
    var header: Text?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                header
                    .font(PK.Font.groupTitle)
                    .foregroundStyle(Color.pkInk2)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pkCard()
        }
    }
}

/// A row: title and optional 12pt description on the left, control on the right.
struct PKRow<Trailing: View>: View {
    let title: Text
    var detail: Text?
    let trailing: Trailing

    init(_ title: Text, detail: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(PK.Font.body).foregroundStyle(Color.pkInk)
                if let detail {
                    detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
    }
}

/// A row of prose, capped near 60 characters.
struct PKNote: View {
    let text: Text

    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(PK.Font.caption)
            .foregroundStyle(Color.pkInk2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PK.Space.lg)
            .padding(.vertical, 11)
    }
}

/// A warning or error as a tinted row. Amber is a status color: only for
/// conflicts and things that need attention.
struct PKCallout: View {
    enum Tone { case warn, error }
    let text: Text
    var symbol = "exclamationmark.triangle.fill"
    var tone: Tone = .warn
    /// Plain information in a callout's place: no tint, Secondary Ink.
    var quiet = false

    init(_ text: Text, symbol: String = "exclamationmark.triangle.fill", tone: Tone = .warn, quiet: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.quiet = quiet
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
            text.font(PK.Font.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(quiet ? Color.pkInk2 : (tone == .warn ? Color.pkWarn : Color.pkRose))
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 10)
        .background(quiet ? Color.clear : (tone == .warn ? Color.pkWarnSoft : Color.pkRose.opacity(0.14)))
    }
}

/// A warn-tinted row that is itself a button ("Restore Caps Lock").
struct PKCalloutButton: View {
    let text: Text
    var symbol = "exclamationmark.triangle.fill"
    let action: () -> Void

    init(_ text: Text, symbol: String = "exclamationmark.triangle.fill", action: @escaping () -> Void) {
        self.text = text
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                text.font(PK.Font.bodyStrong)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.pkWarn)
            .padding(.horizontal, PK.Space.lg)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .background(Color.pkWarnSoft)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A 30pt input: Solid Plate with rim; focus adds the 3pt Indigo Mist halo.
/// Apply to a `TextField`; it sets the plain style itself.
struct PKField: ViewModifier {
    var font = PK.Font.body
    var height: CGFloat = 30
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(Color.pkPlate, in: RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PK.Radius.field, style: .continuous)
                .strokeBorder(focused ? Color.pkIndigo : Color.pkRule, lineWidth: focused ? 1 : 0.5))
            .background(
                RoundedRectangle(cornerRadius: PK.Radius.field + 3, style: .continuous)
                    .fill(Color.pkMist).padding(-3).opacity(focused ? 1 : 0)
            )
    }
}

extension View {
    func pkField(font: Font = PK.Font.body, height: CGFloat = 30) -> some View { modifier(PKField(font: font, height: height)) }
}
