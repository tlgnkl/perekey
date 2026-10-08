// SPDX-License-Identifier: GPL-3.0-or-later

/// The enabled layouts, the one Perekey believes is selected and the one
/// before it. Decides which layout a word goes to (`counterpart(of:)`).
struct LayoutState: Sendable {
    private(set) var maps: [LayoutID: LayoutMap] = [:]
    /// The layouts in the order the system lists them.
    private(set) var order: [LayoutID] = []
    /// The layout Perekey believes is selected: the last one it selected, or
    /// the last one the system reported.
    private(set) var current: LayoutID? {
        didSet { currentMap = current.flatMap { maps[$0] } }
    }
    /// The table of `current`, looked up once per change, not per key.
    private(set) var currentMap: LayoutMap?
    private var previous: LayoutID?

    init(_ maps: [LayoutMap], current: LayoutID?) {
        set(maps)
        self.current = current
        currentMap = current.flatMap { self.maps[$0] }
    }

    subscript(id: LayoutID) -> LayoutMap? { maps[id] }

    mutating func set(_ newMaps: [LayoutMap]) {
        order = newMaps.map(\.id)
        maps = Dictionary(newMaps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        currentMap = current.flatMap { maps[$0] }
    }

    /// Makes `id` the current layout; the current one, if known, becomes the
    /// previous one. False when `id` is current already.
    @discardableResult
    mutating func makeCurrent(_ id: LayoutID) -> Bool {
        guard id != current else { return false }
        if let current, maps[current] != nil { previous = current }
        current = id
        return true
    }

    /// The layout after the current one, for `HotkeyAction.switchLayout`.
    var next: LayoutID? {
        if let current, let index = order.firstIndex(of: current) {
            order[(index + 1) % order.count]
        } else {
            order.first
        }
    }

    /// The first layout of this language.
    func first(language: String) -> LayoutID? {
        order.first { maps[$0]?.language == language }
    }

    /// The layout a word typed in `source` should be retyped into.
    ///
    /// With two layouts it is simply the other one. With more, prefer the
    /// layout the user just switched to (double Shift switches first, then
    /// retypes), then the one used before, then another language.
    func counterpart(of source: LayoutID) -> LayoutID? {
        if let current, current != source, maps[current] != nil { return current }
        if let previous, previous != source, maps[previous] != nil { return previous }
        let language = maps[source]?.language
        var fallback: LayoutID?
        for id in order where id != source {
            if maps[id]?.language != language { return id }
            if fallback == nil { fallback = id }
        }
        return fallback
    }

    /// The layouts a selection may be typed in: the current one first.
    func selectionCandidates() -> [LayoutMap] {
        var candidates: [LayoutMap] = []
        candidates.reserveCapacity(order.count)
        if let current, let map = maps[current] { candidates.append(map) }
        for id in order where id != current {
            if let map = maps[id] { candidates.append(map) }
        }
        return candidates
    }

    /// The synthetic keys of a word retype, or why there are none.
    enum WordKeys {
        case keys((keys: [Retype.Key], expected: String))
        case refused(Refusal)
    }

    /// The synthetic keys that type `entries` in `targetMap`, and the text they
    /// replace.
    func retypeKeys(for entries: some Collection<WordBuffer.Entry>, into targetMap: LayoutMap) -> WordKeys {
        var keys: [Retype.Key] = []
        var expected = ""
        keys.reserveCapacity(entries.count)
        for entry in entries {
            guard let sourceMap = maps[entry.layout], let typed = sourceMap.text(for: entry.stroke),
                  !entry.stroke.modifiers.contains(.option)
            else { return .refused(.unconvertibleWord) }
            guard let text = targetMap.text(for: entry.stroke) else { return .refused(.missingKeys) }
            expected += typed
            keys.append(Retype.Key(stroke: entry.stroke, text: text))
        }
        return .keys((keys, expected))
    }
}
