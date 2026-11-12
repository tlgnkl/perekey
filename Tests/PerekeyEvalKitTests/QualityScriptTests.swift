// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

/// `scripts/quality.sh --check-base` resolves the base and stops, so these tests build and play nothing.
@Suite struct QualityScriptTests {
    struct Result {
        var status: Int32
        var out: String
        var err: String
    }

    static let zeros = String(repeating: "0", count: 40)

    func run(base: String?, event: String?) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Repo.path("scripts/quality.sh"), "--check-base"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["QUALITY_BASE", "GITHUB_EVENT_NAME", "GITHUB_ACTIONS"] { environment[key] = nil }
        if let base { environment["QUALITY_BASE"] = base }
        if let event { environment["GITHUB_EVENT_NAME"] = event }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    @Test func aBaseThatIsGoneIsAnErrorInAPullRequest() throws {
        let result = try run(base: Self.zeros, event: "pull_request")
        #expect(result.status == 2)
        #expect(result.err.contains("not a commit"))
        #expect(!result.out.contains("base:"))
    }

    @Test func aBaseThatIsGoneIsANoteOnAPush() throws {
        // The `before` of the first push of a branch is all zeros.
        let result = try run(base: Self.zeros, event: "push")
        #expect(result.status == 0)
        #expect(result.out.contains("base: none"))
        #expect(result.out.contains("is not a commit here: nothing to compare with"))
    }

    @Test func aBaseThatIsGoneIsANoteOutsideCI() throws {
        let result = try run(base: "no-such-ref-\(UUID().uuidString)", event: nil)
        #expect(result.status == 0)
        #expect(result.out.contains("base: none"))
    }

    @Test func aBaseThatIsACommitIsUsed() throws {
        for event in ["pull_request", "push"] {
            let result = try run(base: "HEAD", event: event)
            #expect(result.status == 0, "\(event): \(result.err)")
            #expect(result.out.contains("base: HEAD"))
        }
    }

    @Test func noBaseIsSaid() throws {
        let result = try run(base: nil, event: "pull_request")
        #expect(result.status == 0)
        #expect(result.out.contains("QUALITY_BASE is not set"))
    }
}
