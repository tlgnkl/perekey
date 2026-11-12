// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A source of text or words that stands behind a set of the pack, with the license it is used under and the
/// words the license asks for (data/SOURCES.md has the check of each against the first source).
enum PackSource: String, CaseIterable, Sendable {
    case tatoeba, stackExchange, wikipediaMisspellings, geonames, wikidata, tldr, wordLists

    var title: String {
        switch self {
        case .tatoeba: "Tatoeba sentences (Russian, English, Ukrainian)"
        case .stackExchange: "Stack Exchange posts (rus, russian and ukrainian sites)"
        case .wikipediaMisspellings: "Wikipedia: Lists of common misspellings / For machines (English)"
        case .geonames: "GeoNames cities15000"
        case .wikidata: "Wikidata given names"
        case .tldr: "tldr-pages 2.3 (English)"
        case .wordLists: "Word frequencies and spelling dictionaries (wordfreq, Hunspell ru_RU, SCOWL en_US-large)"
        }
    }

    var license: String {
        switch self {
        case .tatoeba: "CC BY 2.0 FR; part of the sentences CC0"
        case .stackExchange: "CC BY-SA 2.5, 3.0 or 4.0, by the license of each post"
        case .wikipediaMisspellings: "CC BY-SA 4.0"
        case .geonames: "CC BY 4.0"
        case .wikidata: "CC0 1.0"
        case .tldr: "CC BY 4.0"
        case .wordLists: "wordfreq data CC BY-SA 4.0; Hunspell ru_RU BSD-like; SCOWL permissive (HPND-like)"
        }
    }

    var url: String {
        switch self {
        case .tatoeba: "https://tatoeba.org"
        case .stackExchange: "https://archive.org/details/stackexchange"
        case .wikipediaMisspellings: "https://en.wikipedia.org/wiki/Wikipedia:Lists_of_common_misspellings/For_machines"
        case .geonames: "https://www.geonames.org"
        case .wikidata: "https://www.wikidata.org/wiki/Wikidata:Licensing"
        case .tldr: "https://github.com/tldr-pages/tldr"
        case .wordLists: "https://github.com/rspeer/wordfreq"
        }
    }

    /// What the pack does with the source and how a reader finds the authors.
    var attribution: String {
        switch self {
        case .tatoeba:
            "The sentences were written by the contributors of Tatoeba. A case from a sentence names it in `meta.ref` as "
                + "`tatoeba:<language>#<id>`; the page https://tatoeba.org/sentences/show/<id> shows its author. The sentences "
                + "are used as they are, without changes, apart from the cutting into the steps of a case."
        case .stackExchange:
            "The sentences come from the posts of the users of the Stack Exchange sites `rus.stackexchange.com`, "
                + "`russian.stackexchange.com` and `ukrainian.stackexchange.com` (data dump of April 2024 on archive.org). "
                + "A case names its post in `meta.ref` as `post:<Id>#<n>` (the n-th sentence of the post); the post and its "
                + "author are at `https://<site>/q/<Id>` (a question) or `https://<site>/a/<Id>` (an answer). The code blocks "
                + "of the posts are cut out. Each post keeps the license it carries; the pack as a whole is offered under CC BY-SA 4.0."
        case .wikipediaMisspellings:
            "The pairs «misspelling → correction» are the list of common misspellings of the English Wikipedia (revision "
                + "1199637275 of 27 January 2024), written by its editors."
        case .geonames:
            "The names of cities come from GeoNames (https://www.geonames.org), which is licensed under CC BY 4.0."
        case .wikidata:
            "The given names are a query to Wikidata (released into the public domain under CC0); the file is a snapshot "
                + "of 11 November 2026."
        case .tldr:
            "The names of commands, their options and paths are taken from the pages of tldr-pages, which is licensed under "
                + "CC BY 4.0. The descriptions of the pages are not part of the pack."
        case .wordLists:
            "The words of the sets of classes are picked by rules over the word frequencies of wordfreq (data CC BY-SA 4.0, "
                + "code Apache-2.0), the spelling dictionaries of Hunspell ru_RU (Lebedev, from LibreOffice) and SCOWL "
                + "en_US-large. The pack holds the words the rules picked, not the lists."
        }
    }
}

/// What goes into the pack `perekey-eval cases pack` makes, and what stays out (docs/eval.md, «Пакет случаев»).
///
/// A suite is in the pack only if every source behind it has a license confirmed against the first source
/// (data/SOURCES.md) that allows to pass the text on. Every manifest of `eval/suites` has a decision here, and
/// a test fails on a manifest without one: a new suite does not slip into a public pack by default.
struct PackPolicy: Sendable {
    /// The name of the pack. Decision RE4 (publication and the name) is the owner's: the name is written here
    /// and nowhere else; the file name, the folder in the archive and the texts take it from here.
    static let packageName = "layoutbench-v1-e1"

    struct Entry: Equatable, Sendable {
        var suite: String
        var sources: [PackSource]
    }

    var name: String
    var tier: SuiteManifest.Tier
    var entries: [Entry]
    /// Suites that stay out, each with the reason.
    var excluded: [String: String]
    /// The epoch of the sample; the manifests must hold it.
    var epoch = 1

    var fileName: String { name + ".tar.zst" }

    static let tatoebaSuites = ["prose.tatoeba", "chat.tatoeba", "prose.uk", "typos.none", "typos.synth.equal",
                                "typos.synth.neighbor", "typos.synth.swap", "hyphen", "yo", "doublecap"]
    static let stackExchangeSuites = ["lang.rus-se", "lang.russian-se", "mixed.uk-se"]
    /// Class suites whose words come from the word lists; their warm-up sentences are Tatoeba's.
    static let classSuites = ["class.frequent", "class.short", "class.collision", "protect.url", "protect.captcha",
                              "protect.numbers", "protect.password"]

    static let fullOnly = "Built at the full tier only; the pack is the ci tier (the suites of the ci step of scripts/quality.sh)."
    static let heavy = "Reads ru.stackoverflow.com, a gigabyte (group heavy of scripts/fetch-data.sh); not in the ci tier."

    static let standard = PackPolicy(
        name: packageName, tier: .ci,
        entries: tatoebaSuites.map { Entry(suite: $0, sources: [.tatoeba]) }
            + stackExchangeSuites.map { Entry(suite: $0, sources: [.stackExchange]) }
            + [Entry(suite: "typos.real.en", sources: [.wikipediaMisspellings, .tatoeba])]
            + classSuites.map { Entry(suite: $0, sources: [.wordLists, .tatoeba]) }
            + [Entry(suite: "class.names", sources: [.wordLists, .geonames, .wikidata, .tatoeba]),
               Entry(suite: "class.cli", sources: [.tldr, .wordLists, .tatoeba])],
        excluded: [
            "class.code": "The text is code of six repositories (Apache-2.0, MIT, PostgreSQL License): data/SOURCES.md keeps it out of the public package.",
            "tech.ruso": heavy, "class.oov": heavy, "class.brands": heavy,
            "class.oov.uk": heavy, "class.brands.uk": heavy,
        ].merging(
            ["abbrev", "capslock", "prose.be", "prose.kk", "class.caps", "class.caps.uk", "class.cli.uk", "class.collision.uk",
             "class.frequent.uk", "class.names.uk", "class.punct", "class.punct.uk", "class.short.uk", "class.translit",
             "protect.captcha.uk", "protect.numbers.uk", "protect.password.uk", "protect.url.uk"]
                .map { ($0, fullOnly) }, uniquingKeysWith: { first, _ in first }
        )
    )

    /// Everything wrong with the policy against the manifests of `eval/suites`; empty when it is sound.
    func problems(manifests: [SuiteManifest]) -> [String] {
        var problems: [String] = []
        let included = entries.map(\.suite)
        for suite in Set(included) where included.filter({ $0 == suite }).count > 1 { problems.append("\(suite) is in the pack twice") }
        for entry in entries {
            if entry.suite.hasPrefix("personal.") || entry.suite.hasPrefix("learning.") {
                problems.append("\(entry.suite) is a personal or learning set and never goes in a pack")
            }
            if entry.sources.isEmpty { problems.append("\(entry.suite) has no source to attribute") }
            if excluded[entry.suite] != nil { problems.append("\(entry.suite) is both in the pack and out of it") }
        }
        for (suite, reason) in excluded where reason.isEmpty { problems.append("\(suite) is out of the pack without a reason") }
        let known = Set(manifests.map(\.suite))
        for suite in included where !known.contains(suite) { problems.append("\(suite) has no manifest") }
        for suite in excluded.keys.sorted() where !known.contains(suite) && !manifests.isEmpty {
            problems.append("\(suite) is left out but has no manifest")
        }
        for manifest in manifests.sorted(by: { $0.suite < $1.suite }) {
            if !included.contains(manifest.suite), excluded[manifest.suite] == nil {
                problems.append("\(manifest.suite) has no decision: put it in the pack or leave it out with a reason (PackPolicy)")
            }
            if included.contains(manifest.suite), manifest.epoch != epoch {
                problems.append("\(manifest.suite) is of epoch \(manifest.epoch), the pack holds epoch \(epoch)")
            }
        }
        return problems
    }
}
