// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct OpenRoutingTests {
    @Test func linksAndFilesGoApart() throws {
        let link = try #require(URL(string: "perekey://pause?minutes=5"))
        let file = URL(fileURLWithPath: "/tmp/call.m4a")
        let routing = OpenRouting([link, file, file])
        #expect(routing.links == [link])
        #expect(routing.files == [file, file])
        #expect(routing.ignored == 0)
    }

    @Test func otherSchemesAreIgnored() throws {
        let urls = try ["https://example.com/a.mp3", "ftp://host/a.mp3", "x-apple.systempreferences:a"]
            .map { try #require(URL(string: $0)) }
        let routing = OpenRouting(urls)
        #expect(routing.links.isEmpty)
        #expect(routing.files.isEmpty)
        #expect(routing.ignored == 3)
    }

    @Test func schemeCaseDoesNotMatter() throws {
        let link = try #require(URL(string: "PEREKEY://resume"))
        #expect(OpenRouting([link]).links == [link])
    }

    @Test func aLinkNeverBecomesAFile() throws {
        // A page may put a path into a perekey:// URL; it stays a link for ControlCommand to refuse.
        let link = try #require(URL(string: "perekey://record?file=/etc/passwd"))
        let routing = OpenRouting([link])
        #expect(routing.files.isEmpty)
        #expect(routing.links == [link])
        #expect(ControlCommand.parse(link) == nil)
    }
}
