// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The user's rule for one site, keyed by host in `AppSettings.sites`.
public struct SiteRule: Hashable, Sendable, Codable {
    /// The layout to select whenever the site comes up in a browser.
    public var defaultLayout: LayoutID?
    /// Without a default layout: return to the layout the user left the site with.
    public var rememberLastLayout: Bool

    public init(defaultLayout: LayoutID? = nil, rememberLastLayout: Bool = false) {
        self.defaultLayout = defaultLayout
        self.rememberLastLayout = rememberLastLayout
    }

    private enum CodingKeys: String, CodingKey {
        case defaultLayout, rememberLastLayout
    }

    /// Tolerant: a missing or unknown field falls back to its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultLayout = (try? container.decodeIfPresent(LayoutID.self, forKey: .defaultLayout)) ?? nil
        rememberLastLayout = (try? container.decodeIfPresent(Bool.self, forKey: .rememberLastLayout)) ?? false
    }
}

/// Host names: normalization and matching of a page against the site rules.
public enum SiteHost {
    /// The lowercase host of a URL string or a bare host the user typed, without
    /// "www." and without a trailing dot; `nil` if it is not a valid host name.
    public static func normalized(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        // Cut path, query, fragment, then credentials and port.
        if let end = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<end]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.lastIndex(of: ":") {
            let port = text[text.index(after: colon)...]
            guard port.allSatisfy(\.isASCIINumber) else { return nil }
            text = String(text[..<colon])
        }
        text = text.lowercased()
        while text.hasSuffix(".") { text.removeLast() }
        while text.hasPrefix("www.") { text.removeFirst(4) }
        guard isValid(text) else { return nil }
        return text
    }

    /// Letters, digits and hyphens in dot-separated labels (non-ASCII letters
    /// allowed: IDN hosts are shown decoded), no empty label, no leading or
    /// trailing hyphen.
    public static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0 == "-" || $0.isLetter || $0.isNumber })
            else { return false }
        }
        return true
    }

    /// `host` and its parent domains, longest first, never a bare top-level
    /// domain: "a.b.example.com" gives a.b.example.com, b.example.com, example.com.
    public static func candidates(for host: String) -> [String] {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return labels.isEmpty ? [] : [host] }
        return (0 ..< labels.count - 1).map { labels[$0...].joined(separator: ".") }
    }

    /// The key of the rule that covers `host`, the most specific one.
    public static func ruleKey(for host: String, in rules: [String: SiteRule]) -> String? {
        candidates(for: host).first { rules[$0] != nil }
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}

extension AppSettings {
    /// The site rule that covers `host` (a normalized host), with its key.
    public func siteRule(forHost host: String) -> (key: String, rule: SiteRule)? {
        guard let key = SiteHost.ruleKey(for: host, in: sites), let rule = sites[key] else { return nil }
        return (key, rule)
    }
}
