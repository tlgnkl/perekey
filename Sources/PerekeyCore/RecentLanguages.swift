// SPDX-License-Identifier: GPL-3.0-or-later

/// The languages of the last words of the sentence, the latest first: the
/// context the classifier judges the next word in (docs/classifier.md,
/// «Контекст»). A word whose language was not known takes its place too, as
/// nil: it separates the words around it.
///
/// Fixed slots, no array: it is copied into every `Classifier.Context` on the
/// tap thread.
public struct RecentLanguages: Hashable, Sendable {
    /// How many words back the context reaches.
    public static let capacity = 3

    private var first: String?
    private var second: String?
    private var third: String?
    /// How many slots hold a word.
    public private(set) var count = 0

    public init() {}

    /// From the latest word back; words beyond `capacity` are dropped.
    public init(_ languages: some Sequence<String?>) {
        for language in Array(languages.prefix(Self.capacity)).reversed() { push(language) }
    }

    /// The language of the word `index` words back, 0 for the latest.
    public subscript(index: Int) -> String? {
        switch index {
        case 0: first
        case 1: second
        case 2: third
        default: nil
        }
    }

    public var latest: String? { first }

    /// A word was judged: it is the latest now, and the oldest drops out.
    public mutating func push(_ language: String?) {
        third = second
        second = first
        first = language
        count = min(count + 1, Self.capacity)
    }

    /// The latest word turned out to be in another language (an undo, a
    /// second look at the same word).
    public mutating func replaceLatest(_ language: String?) {
        guard count > 0 else { return push(language) }
        first = language
    }

    /// A sentence ended: only its last word still says something about the
    /// next one.
    public mutating func keepLatest() {
        second = nil
        third = nil
        count = min(count, 1)
    }

    public mutating func removeAll() {
        self = RecentLanguages()
    }
}
