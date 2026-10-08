// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import PerekeyCore

@Suite struct ControlCommandTests {
    private func parse(_ text: String) -> ControlCommand? {
        URL(string: text).flatMap(ControlCommand.parse)
    }

    @Test func pause() {
        #expect(parse("perekey://pause?minutes=30") == .pause(minutes: 30))
        #expect(parse("perekey://pause") == .pause(minutes: 60))
        #expect(parse("perekey://pause/") == .pause(minutes: 60))
        #expect(parse("perekey://pause?minutes=1") == .pause(minutes: 1))
        #expect(parse("perekey://pause?minutes=1440") == .pause(minutes: 1440))
    }

    @Test func pauseRejectsBadMinutes() {
        for bad in ["0", "1441", "-5", "+5", "", "abc", "1e3", "30.5", " 30", "30%20", "٣٠", "99999999999999999999", "0030000"] {
            #expect(parse("perekey://pause?minutes=\(bad)") == nil, Comment(rawValue: "minutes=\(bad)"))
        }
        #expect(parse("perekey://pause?minutes") == nil)
        #expect(parse("perekey://pause?minutes=5&minutes=6") == nil)
        #expect(parse("perekey://pause?minutes=5&x=1") == nil)
        #expect(parse("perekey://pause?x=1") == nil)
    }

    @Test func resume() {
        #expect(parse("perekey://resume") == .resume)
        #expect(parse("perekey://resume?minutes=5") == nil)
    }

    @Test func autoswitch() {
        #expect(parse("perekey://autoswitch?on=1") == .autoswitch(true))
        #expect(parse("perekey://autoswitch?on=0") == .autoswitch(false))
        #expect(parse("perekey://autoswitch") == .autoswitch(nil))
        for bad in ["2", "true", "yes", "", "01", "-1"] {
            #expect(parse("perekey://autoswitch?on=\(bad)") == nil, Comment(rawValue: "on=\(bad)"))
        }
        #expect(parse("perekey://autoswitch?off=1") == nil)
    }

    @Test func mode() {
        #expect(parse("perekey://mode?value=auto") == .mode(.auto))
        #expect(parse("perekey://mode?value=manual") == .mode(.manualOnly))
        #expect(parse("perekey://mode?value=off") == .mode(.off))
        for bad in ["", "Auto", "manualOnly", "on", "auto,off", "auto%20"] {
            #expect(parse("perekey://mode?value=\(bad)") == nil, Comment(rawValue: "value=\(bad)"))
        }
        #expect(parse("perekey://mode") == nil)
        #expect(parse("perekey://mode?mode=off") == nil)
        #expect(parse("perekey://mode?value=off&value=auto") == nil)
    }

    @Test func schemeAndHostAreCaseInsensitive() {
        #expect(parse("PEREKEY://Resume") == .resume)
    }

    @Test func unknownCommandsDoNothing() {
        for text in [
            "perekey://", "perekey:", "perekey:resume", "perekey:///resume", "perekey://words", "perekey://import?url=http://x",
            "perekey://pauseX", "perekey://pause.evil.com", "perekey://resume/extra", "perekey://resume//",
            "perekey://pause/../resume", "perekey://resume#x", "perekey://user@resume", "perekey://user:pw@resume",
            "perekey://resume:80", "other://resume", "https://resume", "perekey2://resume",
        ] {
            #expect(parse(text) == nil, Comment(rawValue: text))
        }
    }

    @Test func injectionLikeStringsDoNothing() {
        for text in [
            "perekey://pause?minutes=5;rm%20-rf%20/",
            "perekey://pause?minutes=5%26x%3D1",
            "perekey://mode?value=off%0Aauto",
            "perekey://mode?value=%27%3B%20drop",
            "perekey://autoswitch?on=1%00",
            "perekey://resume?$(whoami)",
            "perekey://resume?%00",
        ] {
            #expect(parse(text) == nil, Comment(rawValue: text))
        }
    }
}
