// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import PerekeyCore

@Suite struct SettingsSearchTests {
    private enum Pane { case general, words }

    private let search = SettingsSearch(entries: [
        SearchEntry(section: Pane.general, anchor: "typos", texts: ["Исправлять опечатки", "Correct typos"]),
        SearchEntry(section: .general, anchor: "yo", texts: ["Буква ё", "Letter ё"]),
        SearchEntry(section: .words, anchor: "mine", texts: ["Не трогать: мои", "Don't touch: mine"]),
        SearchEntry(section: .words, anchor: "passwords", texts: ["Паролей не храним", "No passwords kept"]),
    ])

    @Test func caseDoesNotMatter() {
        #expect(search.matches(for: "CORRECT").map(\.anchor) == ["typos"])
        #expect(search.matches(for: "опечатки").map(\.anchor) == ["typos"])
    }

    @Test func yoIsYe() {
        #expect(search.matches(for: "буква е").map(\.anchor) == ["yo"])
        #expect(search.matches(for: "letter Ё").map(\.anchor) == ["yo"])
    }

    @Test func aSubstringMatchesAndTheEnglishKeyIsSearched() {
        #expect(search.matches(for: "touch").map(\.anchor) == ["mine"])
        #expect(search.matches(for: "трога").map(\.anchor) == ["mine"])
    }

    @Test func fiveLettersDropTheLast() {
        #expect(SearchText.needle(for: "пароль") == "парол")
        #expect(SearchText.needle(for: "парол") == "паро")
        #expect(SearchText.needle(for: "паро") == "паро")
        #expect(search.matches(for: "пароль").map(\.anchor) == ["passwords"])
    }

    @Test func spacesAroundTheQueryAreIgnored() {
        #expect(SearchText.needle(for: "  Не   трогать ") == "не трогат")
        #expect(search.matches(for: "  typos ").map(\.anchor) == ["typos"])
    }

    @Test func aBlankQueryMatchesNothing() {
        #expect(search.matches(for: "").isEmpty)
        #expect(search.matches(for: "   ").isEmpty)
    }

    @Test func noMatchIsEmpty() {
        #expect(search.matches(for: "zzz").isEmpty)
    }

    @Test func matchesKeepTheOrderOfTheIndexAndCountBySection() {
        let hits = search.matches(for: "е")
        #expect(hits.map(\.anchor) == ["typos", "yo", "mine", "passwords"])
        #expect(Dictionary(grouping: hits, by: \.section).mapValues(\.count) == [.general: 2, .words: 2])
    }

    @Test func returnWalksAndWraps() {
        var walk = SearchWalk()
        #expect([walk.advance(count: 3), walk.advance(count: 3), walk.advance(count: 3), walk.advance(count: 3)] == [0, 1, 2, 0])
    }

    @Test func aNewQueryStartsOver() {
        var walk = SearchWalk()
        _ = walk.advance(count: 3)
        _ = walk.advance(count: 3)
        walk.reset()
        #expect(walk.advance(count: 3) == 0)
    }

    @Test func jumpContinuesFromThere() {
        var walk = SearchWalk()
        walk.jump(to: 1)
        #expect(walk.advance(count: 3) == 2)
    }

    @Test func nothingToWalk() {
        var walk = SearchWalk()
        #expect(walk.advance(count: 0) == nil)
    }

    // MARK: Session

    private let rows = SettingsSearch(entries: [
        SearchEntry(section: Pane.general, anchor: "a1", texts: ["Alpha one"]),
        SearchEntry(section: .general, anchor: "a2", texts: ["Alpha two"], requires: ["extra"]),
        SearchEntry(section: .words, anchor: "b1", texts: ["Alpha three"]),
        SearchEntry(section: .words, anchor: "b2", texts: ["Beta"]),
    ])

    @Test func hiddenRowsAreNotCounted() {
        var session = SearchSession(search: rows)
        session.setQuery("alpha")
        #expect(session.matches.map(\.anchor) == ["a1", "b1"])
        #expect(session.count(in: .general) == 1)
        session.setAvailable(["extra"])
        #expect(session.matches.map(\.anchor) == ["a1", "a2", "b1"])
        #expect(session.count(in: .general) == 2)
    }

    @Test func aRowThatNeedsTwoFlagsNeedsBoth() {
        let two = SettingsSearch(entries: [SearchEntry(section: Pane.general, anchor: "x", texts: ["x"], requires: ["a", "b"])])
        #expect(two.matches(for: "x", available: ["a"]).isEmpty)
        #expect(two.matches(for: "x", available: ["a", "b"]).count == 1)
    }

    @Test func returnWalksTheVisibleMatchesAround() {
        var session = SearchSession(search: rows)
        session.setQuery("alpha")
        #expect([session.next()?.anchor, session.next()?.anchor, session.next()?.anchor] == ["a1", "b1", "a1"])
    }

    @Test func aNewQueryStartsTheWalkOver() {
        var session = SearchSession(search: rows)
        session.setQuery("alpha")
        _ = session.next()
        _ = session.next()
        session.setQuery("alph")
        #expect(session.next()?.anchor == "a1")
    }

    @Test func theFirstMatchOfASectionContinuesTheWalk() {
        var session = SearchSession(search: rows)
        session.setQuery("alpha")
        #expect(session.first(in: .words)?.anchor == "b1")
        #expect(session.next()?.anchor == "a1")
        session.setQuery("beta")
        #expect(session.first(in: .general) == nil)
    }

    @Test func rowsThatAppearOrVanishRestartTheWalk() {
        var session = SearchSession(search: rows)
        session.setQuery("alpha")
        _ = session.next()
        session.setAvailable(["extra"])
        #expect(session.next()?.anchor == "a1")
        session.setAvailable(["extra"])
        #expect(session.next()?.anchor == "a2")
    }

    @Test func aBlankQueryIsNotActive() {
        var session = SearchSession(search: rows)
        #expect(!session.isActive)
        session.setQuery("alpha")
        #expect(session.isActive)
        session.setQuery(" ")
        #expect(!session.isActive && session.matches.isEmpty)
    }
}
