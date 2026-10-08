// SPDX-License-Identifier: GPL-3.0-or-later

import Observation
import SwiftUI

// MARK: - Hatched guarantee row

/// A thing Perekey never touches: a hatched tile, a statement and a sample in
/// monospace. No control: it is a promise, not a setting.
struct PKGuaranteeRow: View {
    let symbol: String
    let title: Text
    var detail: Text?
    /// What such a string looks like; never localized.
    let sample: String

    init(symbol: String, _ title: Text, detail: Text? = nil, sample: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.sample = sample
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HatchTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                title.font(PK.Font.body).foregroundStyle(Color.pkInk)
                if let detail {
                    detail.font(PK.Font.caption).foregroundStyle(Color.pkInk2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: sample)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.pkInk2)
                .padding(.horizontal, 9)
                .frame(minWidth: 96, minHeight: 24)
                .background(Color.pkWash, in: RoundedRectangle(cornerRadius: PK.Radius.keycapSmall, style: .continuous))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, PK.Space.lg)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows that grow and collapse

/// Lays out one child at `progress` of its height, from the top. Animating
/// `progress` is the grid-rows 0fr → 1fr of the design.
private struct RevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * max(progress, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A row enters by growing from zero height and leaves by shrinking to it.
/// Reduce Motion keeps the opacity and drops the height.
private struct RowReveal: Transition {
    let reduced: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let shown: CGFloat = phase.isIdentity ? 1 : 0
        if reduced {
            content.opacity(shown)
        } else {
            RevealLayout(progress: shown) { content.opacity(shown) }
                .clipped()
        }
    }
}

private struct RowTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(RowReveal(reduced: reduceMotion))
    }
}

extension View {
    /// Rows of a list that grow when added and collapse when removed. Pair it
    /// with `pkListChanges(_:)` on the container.
    func pkRowTransition() -> some View { modifier(RowTransition()) }

    /// Animates the rows of this container when `ids` changes.
    func pkListChanges<V: Equatable>(_ ids: V) -> some View {
        animation(PK.Motion.easeOut(0.32), value: ids)
    }
}

// MARK: - Found highlight

/// Which rows should flash: a row that was just added or learned. The row
/// takes its mark when it has played the highlight, so a row that scrolls back
/// into view stays quiet.
@MainActor
@Observable
final class FoundTracker {
    private(set) var ids: Set<String> = []

    func mark(_ id: String) { ids.insert(id) }
    func consume(_ id: String) { ids.remove(id) }
}

/// A strip wipes over the row, rests and peels off: 1.7s in all. Reduce Motion
/// fades it instead.
private struct FoundHighlight: ViewModifier {
    let id: String
    let tracker: FoundTracker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let start = State(initialValue: CGFloat(0))
    private let end = State(initialValue: CGFloat(0))
    private let opacity = State(initialValue: 0.0)

    func body(content: Content) -> some View {
        let wanted = tracker.ids.contains(id)
        content
            .background { strip }
            .task(id: wanted) { if wanted { await play() } }
    }

    private var strip: some View {
        StripFill(shape: Rectangle(), glow: false)
            .mask {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(width: proxy.size.width * max(end.wrappedValue - start.wrappedValue, 0), height: proxy.size.height)
                        .offset(x: proxy.size.width * start.wrappedValue)
                }
            }
            .opacity(opacity.wrappedValue)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func play() async {
        // Also when the row goes away mid-way: the mark must not stay.
        defer { tracker.consume(id) }
        if reduceMotion {
            end.wrappedValue = 1
            withAnimation(.easeOut(duration: 0.2)) { opacity.wrappedValue = 1 }
            guard (try? await Task.sleep(for: .seconds(1.3))) != nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { opacity.wrappedValue = 0 }
            guard (try? await Task.sleep(for: .seconds(0.2))) != nil else { return }
        } else {
            opacity.wrappedValue = 1
            withAnimation(PK.Motion.settle(0.4)) { end.wrappedValue = 1 }
            guard (try? await Task.sleep(for: .seconds(1.1))) != nil else { return }
            withAnimation(PK.Motion.settle(0.4)) { start.wrappedValue = 1 }
            guard (try? await Task.sleep(for: .seconds(0.4))) != nil else { return }
        }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            opacity.wrappedValue = 0
            start.wrappedValue = 0
            end.wrappedValue = 0
        }
    }
}

extension View {
    /// Plays the found highlight behind this row when `tracker` marks `id`.
    func pkFound(_ id: String, tracker: FoundTracker) -> some View {
        modifier(FoundHighlight(id: id, tracker: tracker))
    }
}

// MARK: - Cascade

/// A result that enters with a short offset and fade, `index` × 22ms after
/// the first. Only the first six step; later rows (scrolled into view) appear at once.
private struct CascadeIn: ViewModifier {
    static let step = 0.022
    static let cap = 6

    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shown: State<Bool>

    init(index: Int) {
        self.index = index
        shown = State(initialValue: index >= Self.cap)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown.wrappedValue ? 1 : 0)
            .offset(y: shown.wrappedValue || reduceMotion ? 0 : 4)
            .onAppear {
                guard !shown.wrappedValue else { return }
                withAnimation(PK.Motion.easeOut(0.28).delay(Double(index) * Self.step)) { shown.wrappedValue = true }
            }
    }
}

extension View {
    func pkCascade(index: Int) -> some View { modifier(CascadeIn(index: index)) }
}
