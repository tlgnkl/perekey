// SPDX-License-Identifier: GPL-3.0-or-later

/// How much each language is written in one app or on one site: counts of
/// the words automatic switching judged, by language code, fading with time.
/// Only counts: no word, no letter of what was typed (docs/classifier.md,
/// «Язык программы»).
public struct LanguageCounts: Hashable, Sendable, Codable {
    /// Words per language code, as of `updated`.
    public private(set) var words: [String: Double]
    /// Seconds since 1970 of the last decay.
    public private(set) var updated: Double

    /// A count halves in this many seconds: the mix of an app follows what
    /// the user writes there now, over weeks, not years.
    public static let halfLife: Double = 30 * 86400

    public init(words: [String: Double] = [:], updated: Double = 0) {
        self.words = words
        self.updated = updated
    }

    public var total: Double { words.values.reduce(0, +) }

    /// The counts as they have faded by `time`.
    public func decayed(to time: Double) -> LanguageCounts {
        guard time > updated else { return self }
        let factor = Self.factor(over: time - updated)
        return LanguageCounts(words: words.mapValues { $0 * factor }, updated: time)
    }

    /// Adds the words of a tally, after fading the old ones. A tally may take
    /// back a word counted before (an undone switch): no count goes below zero.
    public mutating func add(_ tally: [String: Int], at time: Double) {
        self = decayed(to: time)
        updated = max(updated, time)
        for (language, count) in tally {
            words[language] = max(0, (words[language] ?? 0) + Double(count))
        }
    }

    /// The language with at least `share` of `minWords` or more words, if
    /// any: what the Apps pane names.
    public func dominant(minWords: Double = 100, share: Double = 0.7) -> String? {
        let total = total
        guard total >= minWords, let top = words.max(by: { $0.value < $1.value }), top.value >= share * total
        else { return nil }
        return top.key
    }

    private static func factor(over seconds: Double) -> Double {
        // 2^(-t/T) without Foundation.
        var factor = 1.0
        var halves = seconds / halfLife
        while halves >= 1 {
            factor *= 0.5
            halves -= 1
        }
        // e^(-x ln 2) by its series: x < 1, eight terms are exact enough.
        let x = halves * 0.693_147_180_559_945
        var term = 1.0
        var sum = 1.0
        for n in 1...8 {
            term *= -x / Double(n)
            sum += term
        }
        return factor * sum
    }
}

/// What the counts of an app or site say about the next word: the log odds
/// of each language, smoothed so a few words say little. The classifier adds
/// the difference of two languages to its score, at most
/// `Classifier.Options.priorLimit` bits either way.
public struct LanguagePrior: Hashable, Sendable {
    /// log2 of the smoothed share of each counted language.
    private var bits: [String: Double] = [:]
    /// The same for a language with no count.
    private var unknownBits = 0.0

    /// Words each language counts as having before any are counted: under a
    /// few hundred words the prior stays weak.
    public static let smoothing = 50.0

    /// No prior: every language alike.
    public init() {}

    public init(counts: [String: Double], smoothing: Double = LanguagePrior.smoothing) {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return }
        let languages = Double(max(2, counts.count))
        let denominator = total + smoothing * languages
        for (language, count) in counts {
            bits[language] = Self.log2((count + smoothing) / denominator)
        }
        unknownBits = Self.log2(smoothing / denominator)
    }

    public var isEmpty: Bool { bits.isEmpty }

    /// Bits in favour of `other` over `typed`: log2 of the ratio of their shares.
    public func lean(toward other: String?, from typed: String?) -> Double {
        guard !bits.isEmpty, let other, let typed, other != typed else { return 0 }
        return (bits[other] ?? unknownBits) - (bits[typed] ?? unknownBits)
    }

    /// log2 without Foundation: the exponent, then the mantissa by its series.
    static func log2(_ value: Double) -> Double {
        guard value > 0 else { return -.infinity }
        let exponent = Double(value.exponent)
        let mantissa = value.significand // in [1, 2)
        // ln(m) = 2 artanh((m - 1) / (m + 1)), which converges fast on [1, 2).
        let y = (mantissa - 1) / (mantissa + 1)
        let y2 = y * y
        var term = y
        var sum = 0.0
        var n = 1.0
        while n < 40 {
            sum += term / n
            term *= y2
            n += 2
        }
        return exponent + 2 * sum / 0.693_147_180_559_945
    }
}

/// The app and the site typing goes to, as the language counts know them,
/// with the prior they give. The app layer sends it on every change
/// (`InputEvent.languageContextChanged`).
public struct LanguageContext: Hashable, Sendable {
    /// Bundle ID of the front app.
    public var app: String?
    /// Normalized host of the page in a browser (`SiteRules.normalized`).
    public var site: String?
    public var prior: LanguagePrior
    /// `LanguageStats.generation` when the context was made: a tally counted
    /// under it before an erase is dropped.
    public var generation: UInt32

    public init(app: String? = nil, site: String? = nil, prior: LanguagePrior = LanguagePrior(),
                generation: UInt32 = 0)
    {
        self.app = app
        self.site = site
        self.prior = prior
        self.generation = generation
    }
}

/// Words judged since the last tally, by language, in one app and site
/// (`Effect.languagesCounted`). A count may be negative: an undo takes back a
/// word counted in the language it was switched to.
public struct LanguageTally: Hashable, Sendable {
    public var app: String?
    public var site: String?
    public var words: [String: Int]
    /// The `LanguageContext.generation` the words were counted under.
    public var generation: UInt32

    public init(app: String?, site: String?, words: [String: Int], generation: UInt32 = 0) {
        self.app = app
        self.site = site
        self.words = words
        self.generation = generation
    }
}

/// The counts of every app and site, as the app layer keeps them.
///
/// Only the apps go to disk. The sites stay in memory and are gone on quit:
/// hosts on disk would be a browsing history, and a list of them is what
/// the counts must never become.
public struct LanguageStats: Hashable, Sendable, Codable {
    public static let version = 1
    public var version = LanguageStats.version
    /// By bundle ID.
    public private(set) var apps: [String: LanguageCounts] = [:]
    /// By normalized host. Never encoded.
    public private(set) var sites: [String: LanguageCounts] = [:]

    /// Bumped by every reset, in memory only. Words the tap counted before
    /// a reset come in later under the old number and are dropped, so an
    /// erased app does not come straight back.
    public private(set) var generation: UInt32 = 0

    /// Sites kept at most, in memory: the least recently counted go first.
    public static let maxSites = 200
    /// Counts below this many words are forgotten.
    static let minWords = 1.0

    public init() {}

    /// A tally counts for its app and, in a browser, for its site too.
    public mutating func record(_ tally: LanguageTally, at time: Double) {
        guard !tally.words.isEmpty, tally.generation == generation else { return }
        if let app = tally.app { apps[app, default: LanguageCounts(updated: time)].add(tally.words, at: time) }
        if let site = tally.site { sites[site, default: LanguageCounts(updated: time)].add(tally.words, at: time) }
    }

    /// The prior for typing in this app and site: the site's counts when it
    /// has enough of its own, else the app's.
    public func prior(app: String?, site: String?, at time: Double) -> LanguagePrior {
        if let site, let counts = sites[site]?.decayed(to: time), counts.total >= LanguagePrior.smoothing {
            return LanguagePrior(counts: counts.words)
        }
        guard let app, let counts = apps[app]?.decayed(to: time) else { return LanguagePrior() }
        return LanguagePrior(counts: counts.words)
    }

    /// The language most typed in the app, once there is enough to say.
    public func dominantLanguage(app: String, at time: Double) -> String? {
        apps[app]?.decayed(to: time).dominant()
    }

    /// Forgets what was counted in the app. `sites`: also every site, which
    /// is counted through the browser.
    public mutating func reset(app: String, sites resetSites: Bool = false) {
        apps[app] = nil
        if resetSites { sites.removeAll() }
        generation &+= 1
    }

    /// Forgets every app and site.
    public mutating func resetAll() {
        apps.removeAll()
        sites.removeAll()
        generation &+= 1
    }

    /// Drops faded counts and the least recently counted sites over `maxSites`.
    public mutating func prune(at time: Double) {
        apps = apps.filter { $0.value.decayed(to: time).total >= Self.minWords }
        sites = sites.filter { $0.value.decayed(to: time).total >= Self.minWords }
        if sites.count > Self.maxSites {
            let oldest = sites.sorted { $0.value.updated < $1.value.updated }.prefix(sites.count - Self.maxSites)
            for (host, _) in oldest { sites[host] = nil }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, apps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
        apps = try container.decodeIfPresent([String: LanguageCounts].self, forKey: .apps) ?? [:]
    }
}
