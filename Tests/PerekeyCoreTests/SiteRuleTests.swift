// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct SiteRuleTests {
    @Test func normalizesHosts() {
        #expect(SiteHost.normalized("GitHub.com") == "github.com")
        #expect(SiteHost.normalized("www.github.com") == "github.com")
        #expect(SiteHost.normalized("https://www.Example.com:8080/a/b?q=1#x") == "example.com")
        #expect(SiteHost.normalized("https://user:pw@docs.github.com/") == "docs.github.com")
        #expect(SiteHost.normalized("  github.com. ") == "github.com")
        #expect(SiteHost.normalized("localhost:3000") == "localhost")
        #expect(SiteHost.normalized("пример.рф") == "пример.рф")
    }

    @Test func rejectsInvalidHosts() {
        for bad in ["", "   ", "a b.com", "-a.com", "a..com", "a.com:x", "exa_mple.com", "https://"] {
            #expect(SiteHost.normalized(bad) == nil, "\(bad)")
        }
    }

    @Test func parentDomainsMatchButNotTopLevel() {
        #expect(SiteHost.candidates(for: "a.b.example.com") == ["a.b.example.com", "b.example.com", "example.com"])
        #expect(SiteHost.candidates(for: "localhost") == ["localhost"])
        let rules = ["github.com": SiteRule(rememberLastLayout: true), "com": SiteRule(rememberLastLayout: true)]
        #expect(SiteHost.ruleKey(for: "docs.github.com", in: rules) == "github.com")
        #expect(SiteHost.ruleKey(for: "gist.github.com", in: rules) == "github.com")
        #expect(SiteHost.ruleKey(for: "other.com", in: rules) == nil)
        #expect(SiteHost.ruleKey(for: "notgithub.com", in: rules) == nil)
    }

    @Test func mostSpecificRuleWins() {
        let settings = AppSettings(sites: [
            "example.com": SiteRule(defaultLayout: "a"),
            "docs.example.com": SiteRule(defaultLayout: "b"),
        ])
        #expect(settings.siteRule(forHost: "x.docs.example.com")?.key == "docs.example.com")
        #expect(settings.siteRule(forHost: "www.example.com".replacingOccurrences(of: "www.", with: ""))?.rule.defaultLayout == "a")
        #expect(settings.siteRule(forHost: "example.org") == nil)
    }

    @Test func roundTripAndTolerantDecoding() throws {
        let settings = AppSettings(sites: ["github.com": SiteRule(defaultLayout: "com.apple.keylayout.ABC")])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"autoswitch":true}"#.utf8))
        #expect(old.sites.isEmpty)
        let broken = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sites":"nope"}"#.utf8))
        #expect(broken.sites.isEmpty)
        let partial = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"sites":{"a.com":{"defaultLayout":5,"extra":1}}}"#.utf8))
        #expect(partial.sites["a.com"] == SiteRule())
    }

    @Test func fileURLsHaveNoHost() {
        #expect(SiteHost.normalized("file:///Users/me/a.html") == nil)
    }
}
