// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// Downloads against servers, disks and callers that misbehave.
@Suite(.timeLimit(.minutes(1))) struct VoiceModelDownloadTests {
    private func failure(_ body: () async throws -> Void) async -> VoiceModelFailure? {
        do {
            try await body()
            return nil
        } catch {
            return error as? VoiceModelFailure
        }
    }

    /// Bytes of a resumed file count once: progress never passes the size.
    @Test func progressAfterAResumeStaysWithinTheSize() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier < 2 {
                // 400 000 bytes, then 100 000 more after the resume.
                response.cutAfter = earlier == 0 ? 400_000 : 100_000
                response.stall = true
            }
            return response
        }
        let store = fixture.store()
        let first = Task { try await store.download("asr") }
        try await fixture.until { VoiceModelStore.size(of: fixture.weightPart) == 400_000 }
        await store.cancelDownload("asr")
        _ = await first.result
        #expect(await store.status(of: "asr")?.state == .partial(received: 400_000))

        let second = Task { try await store.download("asr") }
        try await fixture.until {
            guard case .downloading(let received) = await store.status(of: "asr")?.state else { return false }
            return received > 400_000
        }
        guard case .downloading(let received) = await store.status(of: "asr")?.state else {
            Issue.record("not downloading")
            return
        }
        #expect(received <= 500_000)
        await store.cancelDownload("asr")
        _ = await second.result

        try await store.download("asr")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    /// A proxy's page instead of the rest of a file: the `.part` stays, the
    /// download gives up after its attempts instead of starting over forever.
    @Test func aShortAnswerToARangeLeavesThePartAlone() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            let body = fixture.bodies[request.path]!
            guard request.path == weight else { return TestServer.serve(body, request: request) }
            if earlier == 0 { return TestServer.Response(status: 200, body: body, cutAfter: 250_000) }
            return TestServer.Response(status: 200, body: Data("<html>Sign in to continue</html>".utf8))
        }
        let store = fixture.store(networkAttempts: 3)
        await #expect(throws: VoiceModelFailure.http(status: 200, host: "127.0.0.1")) {
            try await store.download("asr")
        }
        #expect(fixture.server.requests(to: weight).count == 3)
        #expect(VoiceModelStore.size(of: fixture.weightPart) == 250_000)
    }

    @Test func aWriteErrorFailsAtOnce() async throws {
        let fixture = try await Fixture()
        let store = fixture.store { $0.write = { _, _ in throw POSIXError(.ENOSPC) } }
        let failure = await failure { try await store.download("vad") }
        guard case .disk = failure else {
            Issue.record("\(String(describing: failure))")
            return
        }
        #expect(fixture.server.requests.count == 1)
        #expect(await store.status(of: "vad")?.failure == failure)
    }

    @Test func notEnoughSpaceIsRefusedBeforeAnyRequest() async throws {
        let fixture = try await Fixture()
        let store = fixture.store { $0.freeSpace = { _ in 1_000 } }
        // VAD comes first and needs 3 000 bytes.
        await #expect(throws: VoiceModelFailure.notEnoughSpace(needed: 3_000, available: 1_000)) {
            try await store.download("asr")
        }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func aPartThatCannotBeOpenedIsKept() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 { response.cutAfter = 250_000 }
            return response
        }
        let first = fixture.store(networkAttempts: 1)
        await #expect(throws: VoiceModelFailure.self) { try await first.download("asr") }
        let part = fixture.weightPart
        #expect(VoiceModelStore.size(of: part) == 250_000)

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: part.path)
        let store = fixture.store()
        let failure = await failure { try await store.download("asr") }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: part.path)
        guard case .disk = failure else {
            Issue.record("\(String(describing: failure))")
            return
        }
        #expect(VoiceModelStore.size(of: part) == 250_000)
        #expect(fixture.server.requests(to: weight).map(\.range) == [nil, "bytes=250000-"])
    }

    @Test func aRedirectAwayFromTheTrustedHostsIsRefused() async throws {
        let fixture = try await Fixture()
        let port = fixture.server.port
        fixture.server.setHandler { _, _ in
            TestServer.Response(status: 302, headers: ["Location": "http://localhost:\(port)/elsewhere"])
        }
        let store = fixture.store()
        await #expect(throws: VoiceModelFailure.untrustedRedirect(host: "localhost")) {
            try await store.download("vad")
        }
        // Not retried, and the refused host was never asked.
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.http.requests.map(\.host) == ["127.0.0.1"])
    }

    @Test func trustedRedirectsAreHuggingFaceOverHTTPS() {
        let rule = VoiceHTTP.trustedRedirect
        for address in [
            "https://huggingface.co/api/resolve-cache/x", "https://cdn-lfs.huggingface.co/x",
            "https://us.aws.cdn.hf.co/x", "https://cas-bridge.xethub.hf.co/x", "https://HF.CO/x",
        ] {
            #expect(rule(.modelDownload, URL(string: address)!), "\(address)")
        }
        for address in [
            "http://huggingface.co/x", "https://huggingface.co.example.com/x", "https://evilhuggingface.co/x",
            "https://xhf.co/x", "https://example.com/x", "file:///etc/hosts",
        ] {
            #expect(!rule(.modelDownload, URL(string: address)!), "\(address)")
        }
        #expect(!rule(.cloudSpeech, URL(string: "https://huggingface.co/x")!))
    }

    @Test func serverErrorsAreRetried() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            if request.path == weight, earlier < 2 { return TestServer.Response(status: earlier == 0 ? 503 : 500) }
            return TestServer.serve(fixture.bodies[request.path]!, request: request)
        }
        let store = fixture.store()
        try await store.download("asr")
        #expect(fixture.server.requests(to: weight).count == 3)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func serverErrorsStopAtTheLimit() async throws {
        let fixture = try await Fixture { _, _ in TestServer.Response(status: 502) }
        let store = fixture.store(networkAttempts: 3)
        await #expect(throws: VoiceModelFailure.http(status: 502, host: "127.0.0.1")) {
            try await store.download("vad")
        }
        #expect(fixture.server.requests.count == 3)
    }

    /// Writes `bytes` of the weight file as the `.part` of an interrupted download.
    private func interrupted(_ fixture: Fixture, bytes: Int) throws {
        let partial = fixture.locations.models.appending(path: "asr.partial")
        try FileManager.default.createDirectory(
            at: fixture.weightPart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VoiceModelStore.manifest(of: fixture.asr).write(
            to: partial.appending(path: VoiceModelStore.manifestName), atomically: true, encoding: .utf8)
        try fixture.bodies[fixture.weightPath]!.prefix(bytes).write(to: fixture.weightPart)
    }

    /// A whole `.part` is checked against its SHA-256 without asking for more:
    /// no `Range` past the end, no 416.
    @Test func aWholePartIsCheckedWithoutARequest() async throws {
        let fixture = try await Fixture()
        try interrupted(fixture, bytes: 600_000)
        let store = fixture.store()
        #expect(await store.status(of: "asr")?.state == .partial(received: 600_000))
        try await store.download("asr")
        #expect(fixture.server.requests(to: fixture.weightPath).isEmpty)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    /// A 416 means the server has nothing past the `.part`: its checksum
    /// decides, and a wrong one starts the file over.
    @Test func a416IsSettledByTheChecksum() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        try interrupted(fixture, bytes: 250_000)
        fixture.server.setHandler { request, _ in
            if request.path == weight, request.range != nil {
                return TestServer.Response(status: 416, headers: ["Content-Range": "bytes */250000"])
            }
            return TestServer.serve(fixture.bodies[request.path]!, request: request)
        }
        let store = fixture.store()
        try await store.download("asr")
        #expect(fixture.server.requests(to: weight).map(\.range) == ["bytes=250000-", nil])
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func twoDownloadsOfOneModelShareTheRequests() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        async let first: Void = store.download("asr")
        async let second: Void = store.download("asr")
        _ = try await (first, second)
        for (path, _) in fixture.bodies where !path.hasPrefix("/org/other/") {
            #expect(fixture.server.requests(to: path).count == 1, "\(path)")
        }
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    /// The Voice tab waits from `.task`: leaving the tab ends the wait, not the download.
    @Test func cancellingTheCallerLeavesTheDownloadRunning() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 { response.cutAfter = 300_000 }
            return response
        }
        let store = fixture.store()
        let caller = Task { try await store.download("asr") }
        try await fixture.until { !fixture.server.requests(to: weight).isEmpty }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await fixture.until { await store.status(of: "asr")?.state == .ready }
        #expect(fixture.server.requests(to: weight).last?.range == "bytes=300000-")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    /// A download asked for while a delete stops the last one either runs
    /// after the delete or is stopped by it; the files never mix.
    @Test func aDownloadDuringADeleteNeverMixes() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 {
                response.cutAfter = 100_000
                response.stall = true
            }
            return response
        }
        let store = fixture.store()
        let first = Task { try await store.download("asr") }
        try await fixture.until { VoiceModelStore.size(of: fixture.weightPart) == 100_000 }
        async let deleting: Void = store.delete("asr")
        let second = Task { try await store.download("asr") }
        try await deleting
        _ = await first.result
        switch await second.result {
        case .success:
            #expect(await store.status(of: "asr")?.state == .ready)
            #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
        case .failure(let error):
            #expect(error is CancellationError, "\(error)")
            #expect(await store.status(of: "asr")?.state == .absent)
            #expect(!fixture.exists(fixture.locations.models.appending(path: "asr.partial")))
        }
    }

    @Test func aHeldDamagedModelIsNotRepaired() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        let folder = try await store.acquire("asr")
        let mil = folder.appending(path: "Encoder.mlmodelc/model.mil")
        try Data(count: 10).write(to: mil)
        await store.refresh()
        #expect(await store.status(of: "asr")?.state == .damaged)
        let requests = fixture.server.requests.count

        await #expect(throws: VoiceModelFailure.inUse("asr")) { try await store.download("asr") }
        #expect(fixture.server.requests.count == requests)
        #expect(fixture.exists(mil) && fixture.exists(folder))

        await store.release("asr")
        try await store.download("asr")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func trashLeftByACrashIsRemoved() async throws {
        let fixture = try await Fixture()
        let trash = fixture.locations.models.appending(path: "asr.trash-1")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = fixture.store()
        #expect(!fixture.exists(trash))

        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        await store.refresh()
        #expect(!fixture.exists(trash))
    }

    @Test func vadStaysWhileARecognizerNeedsIt() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        await #expect(throws: VoiceModelFailure.requiredBy("asr")) { try await store.delete("vad") }
        #expect(await store.status(of: "vad")?.state == .ready)
        try await store.delete("asr")
        try await store.delete("vad")
        #expect(await store.status(of: "vad")?.state == .absent)

        // A recognizer is not handed out without VAD.
        try fixture.place(fixture.asr, in: fixture.folder("asr"))
        let other = fixture.store()
        await #expect(throws: VoiceModelFailure.notReady("vad")) { _ = try await other.acquire("asr") }
    }

    @Test func waitingForANetworkShowsAndEnds() async throws {
        let fixture = try await Fixture(connectivityTimeout: 0.5)
        let weight = fixture.weightPath
        fixture.server.setHandler { request, _ in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight {
                response.cutAfter = 100_000
                response.stall = true
            }
            return response
        }
        let store = fixture.store()
        let download = Task { try await store.download("asr") }
        try await fixture.until { VoiceModelStore.size(of: fixture.weightPart) == 100_000 }
        // URLSession says so when the network goes away; here the test does.
        for task in await fixture.http.session.allTasks {
            fixture.http.router.urlSession(fixture.http.session, taskIsWaitingForConnectivity: task)
        }
        try await fixture.until {
            guard case .waitingForNetwork = await store.status(of: "asr")?.state else { return false }
            return true
        }
        await #expect(throws: VoiceModelFailure.offline) { try await download.value }
        let status = await store.status(of: "asr")
        #expect(status?.failure == .offline)
        #expect(status?.state == .partial(received: 100_000))
    }
}
