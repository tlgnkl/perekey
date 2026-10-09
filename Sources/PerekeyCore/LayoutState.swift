// SPDX-License-Identifier: GPL-3.0-or-later

/// The enabled layouts, the one Perekey believes is selected and the one
/// before it. Decides which layouts a word may go to (`candidates(of:)`) and
/// which one first (`counterpart(of:)`).
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
    /// The layouts in the order they were last selected, the latest first:
    /// `current`, the one before it, and so on. Which Cyrillic layout the
    /// user used last decides between ru and uk when nothing else does.
    private var used: [LayoutID] = []
    /// What automatic switching weighs a word of `current` against:
    /// `candidates(of: current)` of another script
    /// (`Classifier.switchesAutomatically`). Kept per change, not per word.
    private(set) var automaticCandidates: [LayoutMap] = []
    /// The languages whose typos the judge's corrector fixes
    /// (`TypoCorrector.Options.languages`); `InputMachine` keeps it in step.
    var typoLanguages: Set<String> = TypoCorrector.Options().languages {
        didSet {
            guard typoLanguages != oldValue else { return }
            for index in scripted.indices {
                scripted[index].typos = scripted[index].map.language.map(typoLanguages.contains) ?? false
            }
        }
    }
    /// The layouts in `order` with the script of their language, looked up
    /// once per set of layouts: `updateCandidates` runs on every layout
    /// change and hashes nothing.
    /// `typos`: the layout's language is one of `typoLanguages`, asked once
    /// here, not per word.
    private var scripted: [(map: LayoutMap, script: Classifier.Script?, typos: Bool)] = []

    init(_ maps: [LayoutMap], current: LayoutID?) {
        set(maps)
        self.current = current
        if let current { used = [current] }
        currentMap = current.flatMap { self.maps[$0] }
        updateCandidates()
    }

    subscript(id: LayoutID) -> LayoutMap? { maps[id] }

    mutating func set(_ newMaps: [LayoutMap]) {
        order = newMaps.map(\.id)
        maps = Dictionary(newMaps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        scripted = order.compactMap { id in
            maps[id].map { map in
                (map, map.language.flatMap(Classifier.Script.init), map.language.map(typoLanguages.contains) ?? false)
            }
        }
        currentMap = current.flatMap { maps[$0] }
        updateCandidates()
    }

    /// Makes `id` the current layout; the current one, if known, becomes the
    /// previous one. False when `id` is current already.
    @discardableResult
    mutating func makeCurrent(_ id: LayoutID) -> Bool {
        guard id != current else { return false }
        used.removeAll { $0 == id }
        used.insert(id, at: 0)
        if used.count > 16 { used.removeLast() }
        current = id
        updateCandidates()
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

    /// The layout a word typed in `source` should be retyped into: the first
    /// of `candidates(of:)`. With only layouts of the source's language, the
    /// one the user switched to, the one before, or the first of them.
    ///
    /// With two layouts it is simply the other one.
    func counterpart(of source: LayoutID) -> LayoutID? {
        let language = scripted.first { $0.map.id == source }?.map.language
        var found: LayoutID?
        var fallback: LayoutID?
        visitPreferred { map in
            guard map.id != source else { return true }
            if fallback == nil { fallback = map.id }
            guard language == nil || map.language != language else { return true }
            found = map.id
            return false
        }
        return found ?? fallback
    }

    /// The layouts a word typed in `source` may have been meant for, one per
    /// language other than the source's: layouts of one language (ABC and US
    /// Extended) type the same letters and never compete. The layout the
    /// user just switched to comes first (double Shift switches first, then
    /// retypes), then the one used before, then the system order. A layout
    /// of no known language stands for itself.
    func candidates(of source: LayoutID) -> [LayoutID] {
        let sourceLanguage = scripted.first { $0.map.id == source }?.map.language
        var candidates: [LayoutMap] = []
        visitPreferred { map in
            guard map.id != source else { return true }
            if let language = map.language {
                guard language != sourceLanguage, !candidates.contains(where: { $0.language == language }) else {
                    return true
                }
            }
            candidates.append(map)
            return true
        }
        return candidates.map(\.id)
    }

    /// Whether typos of words in this layout are corrected: its language
    /// passed the typo gate. A linear look among a handful of layouts.
    func correctsTypos(_ id: LayoutID) -> Bool {
        scripted.first { $0.map.id == id }?.typos ?? false
    }

    /// `current`, then the layouts by when they were last used, then the
    /// system order, no layout twice, until `body` returns false. Linear
    /// over a handful of layouts: no hashing on the way of a retype.
    private func visitPreferred(_ body: (LayoutMap) -> Bool) {
        var seen: UInt64 = 0
        func visit(_ index: Int) -> Bool {
            let bit: UInt64 = index < 64 ? 1 << UInt64(index) : 0
            guard seen & bit == 0 else { return true }
            seen |= bit
            return body(scripted[index].map)
        }
        if let current, let index = scripted.firstIndex(where: { $0.map.id == current }), !visit(index) { return }
        for id in used {
            if let index = scripted.firstIndex(where: { $0.map.id == id }), !visit(index) { return }
        }
        for index in scripted.indices where !visit(index) { return }
    }

    /// `candidates(of: current)` of another script, without the arrays of
    /// `candidates`: it runs on every layout change, a few times a second
    /// while typing. The layout used last comes first.
    private mutating func updateCandidates() {
        automaticCandidates.removeAll(keepingCapacity: true)
        guard let current, let script = scripted.first(where: { $0.map.id == current })?.script else { return }
        for id in used where id != current {
            if let index = scripted.firstIndex(where: { $0.map.id == id }) { consider(index, against: script) }
        }
        for index in scripted.indices { consider(index, against: script) }
    }

    private mutating func consider(_ index: Int, against script: Classifier.Script) {
        let (map, other, _) = scripted[index]
        guard let other, other != script,
              !automaticCandidates.contains(where: { $0.language == map.language })
        else { return }
        automaticCandidates.append(map)
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
