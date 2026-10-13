// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import PerekeyCore
@testable import PerekeyVoice
import PerekeyVoiceCore
import Testing

/// A catalog of small random models, their files on a `TestServer` and a
/// store over a temporary folder.
final class Fixture: @unchecked Sendable {
    static let commit = String(repeating: "a1", count: 20)
    static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    let root: URL
    let locations: VoiceModelLocations
    let http: VoiceHTTP
    let server: TestServer
    /// Server path of every file → its bytes.
    let bodies: [String: Data]
    let asr: VoiceModelEntry
    let other: VoiceModelEntry
    let vad: VoiceModelEntry
    var catalog: [VoiceModelEntry] { [asr, other, vad] }

    init(handler: TestServer.Handler? = nil, connectivityTimeout: TimeInterval = 120) async throws {
        // Redirects stay on the test server, as they stay on Hugging Face.
        http = VoiceHTTP(
            allowed: [.modelDownload], requestTimeout: 5, connectivityTimeout: connectivityTimeout,
            redirects: { _, url in url.host() == "127.0.0.1" })
        root = FileManager.default.temporaryDirectory.appending(path: "perekey-voice-tests-\(UUID().uuidString)")
        locations = VoiceModelLocations(
            models: root.appending(path: "VoiceModels"), managed: root.appending(path: "Managed"),
            coreMLCache: root.appending(path: "Caches/com.apple.e5rt.e5bundlecache"))
        var bodies: [String: Data] = [:]
        func file(_ path: String, remote: String? = nil, repo: String, size: Int) -> VoiceModelFile {
            // Byte by byte, a debug build spends seconds of every core on the
            // fixtures of the suite and starves the timing tests beside them.
            var data = Data(count: size)
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, size) }
            let encoded = (remote ?? path).split(separator: "/").map {
                $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            }.joined(separator: "/")
            bodies["/\(repo)/resolve/\(Self.commit)/\(encoded)"] = data
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return VoiceModelFile(path: path, remotePath: remote, size: Int64(size), sha256: hash)
        }
        asr = VoiceModelEntry(
            id: "asr", title: "ASR", engine: .fluidAudioAsr, languages: ["ru"],
            sources: [
                VoiceModelSource(repo: "org/asr", commit: Self.commit, files: [
                    file("Encoder.mlmodelc/weights/weight.bin", repo: "org/asr", size: 600_000),
                    file("Encoder.mlmodelc/model.mil", repo: "org/asr", size: 2_000),
                    file("with space/é.json", repo: "org/asr", size: 10),
                ]),
                VoiceModelSource(repo: "org/tokenizer", commit: Self.commit, files: [
                    file("tokenizer/vocab.json", remote: "vocab.json", repo: "org/tokenizer", size: 5_000),
                ]),
            ])
        other = VoiceModelEntry(
            id: "other", title: "Other", engine: .whisperKit, languages: ["*"],
            sources: [VoiceModelSource(repo: "org/other", commit: Self.commit, files: [
                file("weights.bin", repo: "org/other", size: 50_000),
            ])])
        vad = VoiceModelEntry(
            id: "vad", title: "VAD", engine: .fluidAudioVad, languages: ["*"],
            sources: [VoiceModelSource(repo: "org/vad", commit: Self.commit, files: [
                file("vad.mlmodelc/weights/weight.bin", repo: "org/vad", size: 3_000),
            ])])
        self.bodies = bodies
        server = try await TestServer(handler ?? TestServer.files(bodies))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func store(
        _ managed: ManagedSettings = ManagedSettings(), networkAttempts: Int = 3,
        configure: (inout VoiceModelStore.Limits) -> Void = { _ in }
    ) -> VoiceModelStore {
        var limits = VoiceModelStore.Limits()
        limits.networkAttempts = networkAttempts
        limits.retryDelay = { _ in .zero }
        configure(&limits)
        return VoiceModelStore(
            catalog: catalog, locations: locations, managed: managed, http: http, host: server.base, limits: limits)
    }

    func path(of file: String) -> String { bodies.keys.first { $0.hasSuffix("/" + file) }! }

    var weightPath: String { path(of: "Encoder.mlmodelc/weights/weight.bin") }

    func folder(_ id: String) -> URL { locations.models.appending(path: id, directoryHint: .isDirectory) }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Writes a model straight into `folder`, as a finished download or an administrator would.
    func place(_ entry: VoiceModelEntry, in folder: URL, manifest: Bool = true) throws {
        for source in entry.sources {
            for file in source.files {
                let url = folder.appending(path: file.path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let remote = bodies.first { $0.key.hasPrefix("/\(source.repo)/") && $0.value.count == file.size && SHA256.hash(data: $0.value).map { String(format: "%02x", $0) }.joined() == file.sha256 }!
                try remote.value.write(to: url)
            }
        }
        if manifest {
            try VoiceModelStore.manifest(of: entry).write(
                to: folder.appending(path: VoiceModelStore.manifestName), atomically: true, encoding: .utf8)
        }
    }

    func fillCache() throws {
        try FileManager.default.createDirectory(at: locations.coreMLCache.appending(path: "26A434/KEY"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: locations.coreMLCache.appending(path: "26A434/KEY/model.bundle"))
    }

    func filesMatch(_ entry: VoiceModelEntry, in folder: URL) -> Bool {
        (try? VoiceModelStore.verifyChecksums(of: entry, in: folder)) != nil
    }

    var weightPart: URL {
        locations.models.appending(path: "asr.partial/Encoder.mlmodelc/weights/weight.bin.part")
    }

    /// Polls until `condition` holds; the suite's time limit ends a wait that never does.
    func until(_ condition: () async -> Bool) async throws {
        while await !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func partFiles() -> [String] {
        let walker = FileManager.default.enumerator(atPath: locations.models.path)
        return (walker?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
    }
}

@Suite(.timeLimit(.minutes(1))) struct VoiceModelStoreTests {
    @Test func downloadsChecksAndRenamesIntoPlace() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        #expect(await store.status(of: "asr")?.state == .absent)
        try await store.download("asr")

        #expect(await store.status(of: "asr")?.state == .ready)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
        #expect(fixture.exists(fixture.folder("asr").appending(path: "tokenizer/vocab.json")))
        #expect(!fixture.exists(fixture.locations.models.appending(path: "asr.partial")))
        #expect(fixture.partFiles().isEmpty)
        // The path is percent-encoded segment by segment.
        #expect(fixture.server.requests.contains { $0.target == "/org/asr/resolve/\(Fixture.commit)/with%20space/%C3%A9.json?download=true" })
        #expect(await store.folder(of: "asr") == fixture.folder("asr"))
    }

    @Test func vadComesWithTheFirstRecognizer() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        #expect(await store.status(of: "vad")?.state == .ready)
        #expect(fixture.filesMatch(fixture.vad, in: fixture.folder("vad")))

        let before = fixture.server.requests.count
        try await store.download("other")
        // VAD is there already: only the new model's file.
        #expect(fixture.server.requests.count == before + 1)
    }

    @Test func aFileWithAWrongChecksumIsDownloadedAgain() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 {
                response.body = Data(repeating: 0, count: response.body.count)
            }
            return response
        }
        let store = fixture.store()
        try await store.download("asr")
        #expect(await store.status(of: "asr")?.state == .ready)
        #expect(fixture.server.requests(to: weight).count == 2)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func checksumFailuresStopAtTheLimit() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, _ in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight { response.body = Data(repeating: 1, count: response.body.count) }
            return response
        }
        let store = fixture.store()
        await #expect(throws: VoiceModelFailure.checksumMismatch("Encoder.mlmodelc/weights/weight.bin")) {
            try await store.download("asr")
        }
        #expect(fixture.server.requests(to: weight).count == 3)
        #expect(!fixture.exists(fixture.folder("asr")))
        let status = await store.status(of: "asr")
        #expect(status?.failure == .checksumMismatch("Encoder.mlmodelc/weights/weight.bin"))
        guard case .partial = status?.state else { Issue.record("state \(String(describing: status?.state))"); return }
    }

    @Test func aBrokenConnectionResumesWithRange() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 { response.cutAfter = 250_000 }
            return response
        }
        let store = fixture.store()
        try await store.download("asr")
        let requests = fixture.server.requests(to: weight)
        #expect(requests.count == 2)
        #expect(requests.first?.range == nil)
        #expect(requests.last?.range == "bytes=250000-")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func aServerWithoutRangeStartsOver() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request, ranges: false)
            if request.path == weight, earlier == 0 { response.cutAfter = 250_000 }
            return response
        }
        let store = fixture.store()
        try await store.download("asr")
        let requests = fixture.server.requests(to: weight)
        #expect(requests.count == 2)
        #expect(requests.last?.range == "bytes=250000-")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func aWrongContentRangeStartsOver() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            let body = fixture.bodies[request.path]!
            if request.path == weight, earlier == 0 {
                return TestServer.Response(status: 200, body: body, cutAfter: 100_000)
            }
            if request.path == weight, earlier == 1 {
                // Asked from 100000, answers from 10.
                return TestServer.Response(
                    status: 206, headers: ["Content-Range": "bytes 10-\(body.count - 1)/\(body.count)"],
                    body: body.subdata(in: 10..<body.count))
            }
            return TestServer.serve(body, request: request)
        }
        let store = fixture.store()
        try await store.download("asr")
        let requests = fixture.server.requests(to: weight)
        #expect(requests.map(\.range) == [nil, "bytes=100000-", nil])
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func anExpiredCDNLinkGoesBackToTheOrigin() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        let base = fixture.server.base
        fixture.server.setHandler { request, earlier in
            if request.path.hasPrefix("/cdn/") {
                let origin = String(request.path.dropFirst(4))
                // The first two signed links have expired by the time they are used.
                if origin == weight, request.target.hasSuffix("sig=0") {
                    return TestServer.Response(status: 403)
                }
                if origin == weight, request.target.hasSuffix("sig=1") {
                    return TestServer.Response(status: 410)
                }
                return TestServer.serve(fixture.bodies[origin]!, request: request)
            }
            return TestServer.Response(status: 302, headers: ["Location": "\(base)/cdn\(request.path)?sig=\(earlier)"])
        }
        let store = fixture.store()
        try await store.download("asr")
        #expect(fixture.server.requests(to: weight).count == 3)
        #expect(fixture.server.requests(to: "/cdn" + weight).count == 3)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
        // Redirects count as requests of the download.
        let requests = fixture.http.requests
        #expect(!requests.isEmpty && requests.allSatisfy { $0.purpose == .modelDownload && $0.host == "127.0.0.1" })
        #expect(requests.count == fixture.server.requests.count)
    }

    @Test(arguments: [403, 410]) func anOriginRefusalIsNotRetried(status: Int) async throws {
        let fixture = try await Fixture { _, _ in TestServer.Response(status: status) }
        let store = fixture.store()
        await #expect(throws: VoiceModelFailure.http(status: status, host: "127.0.0.1")) {
            try await store.download("vad")
        }
        #expect(fixture.server.requests.count == 1)
    }

    @Test func anInterruptedDownloadIsNeverReadyAndResumesAfterRestart() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 { response.cutAfter = 300_000 }
            return response
        }
        // One failed request and the download gives up, like a quit app.
        let first = fixture.store(networkAttempts: 1)
        await #expect(throws: VoiceModelFailure.self) { try await first.download("asr") }
        #expect(!fixture.exists(fixture.folder("asr")))
        #expect(fixture.exists(fixture.locations.models.appending(path: "asr.partial")))
        guard case .partial(let received) = await first.status(of: "asr")?.state else {
            Issue.record("not partial")
            return
        }
        #expect(received == 300_000)

        // A new store, as after a restart, picks the partial folder up.
        let second = fixture.store()
        #expect(await second.status(of: "asr")?.state == .partial(received: received))
        #expect(await second.folder(of: "asr") == nil)
        await #expect(throws: VoiceModelFailure.notReady("asr")) { _ = try await second.acquire("asr") }
        try await second.download("asr")
        #expect(fixture.server.requests(to: weight).last?.range == "bytes=300000-")
        #expect(fixture.server.requests(to: fixture.path(of: "model.mil")).count == 1)
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func readyAtLaunchMeansEveryFileWithItsSize() async throws {
        let fixture = try await Fixture()
        try await fixture.store().download("asr")
        let requests = fixture.server.requests.count

        #expect(await fixture.store().status(of: "asr")?.state == .ready)

        // A truncated file: damaged at the next launch.
        let weight = fixture.folder("asr").appending(path: "Encoder.mlmodelc/weights/weight.bin")
        let handle = try FileHandle(forWritingTo: weight)
        try handle.truncate(atOffset: 1_000)
        try handle.close()
        let store = fixture.store()
        #expect(await store.status(of: "asr")?.state == .damaged)

        // Downloading again checks the intact files and fetches the rest of the broken one.
        try await store.download("asr")
        #expect(await store.status(of: "asr")?.state == .ready)
        #expect(fixture.server.requests.count == requests + 1)
        #expect(fixture.server.requests.last?.range == "bytes=1000-")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func anotherCatalogCommitMakesAModelDamaged() async throws {
        let fixture = try await Fixture()
        try fixture.place(fixture.other, in: fixture.folder("other"), manifest: false)
        try "org/other@0000\n".write(
            to: fixture.folder("other").appending(path: VoiceModelStore.manifestName), atomically: true, encoding: .utf8)
        #expect(await fixture.store().status(of: "other")?.state == .damaged)
    }

    @Test func cancellingKeepsWhatArrived() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        let cut = 300_000
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight, earlier == 0 {
                response.cutAfter = cut
                response.stall = true
            }
            return response
        }
        let store = fixture.store()
        let download = Task { try await store.download("asr") }
        try await fixture.until { VoiceModelStore.size(of: fixture.weightPart) == Int64(cut) }
        await store.cancelDownload("asr")
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(await store.status(of: "asr")?.state == .partial(received: Int64(cut)))
        #expect(await store.status(of: "asr")?.failure == nil)

        try await store.download("asr")
        #expect(fixture.server.requests(to: weight).last?.range == "bytes=\(cut)-")
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
    }

    @Test func deleteRefusesAHeldModel() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        try fixture.fillCache()

        let folder = try await store.acquire("asr")
        #expect(folder == fixture.folder("asr"))
        #expect(await store.status(of: "asr")?.isInUse == true)
        await #expect(throws: VoiceModelFailure.inUse("asr")) { try await store.delete("asr") }
        #expect(fixture.filesMatch(fixture.asr, in: fixture.folder("asr")))
        #expect(fixture.exists(fixture.locations.coreMLCache))

        await store.release("asr")
        try await store.delete("asr")
        #expect(!fixture.exists(fixture.folder("asr")))
        // Other models' compiled forms stay: compiling one again costs minutes.
        #expect(fixture.exists(fixture.locations.coreMLCache))
        #expect(await store.status(of: "asr")?.state == .absent)
        #expect(await store.status(of: "vad")?.state == .ready)
    }

    @Test func theCacheWaitsForTheLastHolder() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        try await store.download("other")
        try fixture.fillCache()

        _ = try await store.acquire("asr")
        _ = try await store.acquire("asr")
        try await store.delete("other")
        #expect(fixture.exists(fixture.locations.coreMLCache))
        #expect(try await store.deleteAll() == ["asr", "vad"])
        #expect(!fixture.exists(fixture.folder("other")))
        // A loaded model may still read its compiled form.
        #expect(fixture.exists(fixture.locations.coreMLCache))
        await store.release("asr")
        #expect(fixture.exists(fixture.locations.coreMLCache))
        await store.release("asr")
        #expect(!fixture.exists(fixture.locations.coreMLCache))
    }

    @Test func deletingADownloadStopsIt() async throws {
        let fixture = try await Fixture()
        let weight = fixture.weightPath
        fixture.server.setHandler { request, earlier in
            var response = TestServer.serve(fixture.bodies[request.path]!, request: request)
            if request.path == weight { response.cutAfter = 100_000; response.stall = true }
            return response
        }
        let store = fixture.store()
        let download = Task { try await store.download("asr") }
        try await fixture.until { !fixture.server.requests(to: weight).isEmpty }
        try await store.delete("asr")
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(await store.status(of: "asr")?.state == .absent)
        #expect(!fixture.exists(fixture.locations.models.appending(path: "asr.partial")))
    }

    @Test func deleteAllKeepsHeldModelsAndRemovesLeftovers() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        try await store.download("asr")
        try await store.download("other")
        try fixture.fillCache()
        let models = fixture.locations.models
        // An older catalog's model, an interrupted swap and a file that is not ours.
        try fixture.place(fixture.other, in: models.appending(path: "retired-model"))
        try FileManager.default.createDirectory(at: models.appending(path: "asr.trash-1"), withIntermediateDirectories: true)
        try Data().write(to: models.appending(path: "notes.txt"))

        _ = try await store.acquire("other")
        let kept = try await store.deleteAll()
        // VAD stays with the held recognizer.
        #expect(kept == ["other", "vad"])
        #expect(fixture.filesMatch(fixture.other, in: fixture.folder("other")))
        #expect(fixture.filesMatch(fixture.vad, in: fixture.folder("vad")))
        for gone in ["asr", "retired-model", "asr.trash-1"] {
            #expect(!fixture.exists(models.appending(path: gone)), "\(gone)")
        }
        #expect(fixture.exists(models.appending(path: "notes.txt")))
        #expect(await store.status(of: "asr")?.state == .absent)

        await store.release("other")
        #expect(!fixture.exists(fixture.locations.coreMLCache))
        #expect(try await store.deleteAll().isEmpty)
        #expect(!fixture.exists(fixture.folder("other")) && !fixture.exists(fixture.folder("vad")))
    }

    @Test func diskUsageCountsModelsAndTheCache() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        #expect(await store.diskUsage().total == 0)
        try await store.download("other")
        try fixture.fillCache()
        let usage = await store.diskUsage()
        #expect(usage.models >= 50_000)
        #expect(usage.cache >= 10_000)
        #expect(usage.total == usage.models + usage.cache)
    }

    @Test func statusesShowSizeAndAddress() async throws {
        let fixture = try await Fixture()
        let store = fixture.store()
        let status = try #require(await store.status(of: "asr"))
        // The recognizer brings VAD along.
        #expect(status.size == 607_010 + 3_000)
        #expect(status.addresses == [
            "https://huggingface.co/org/asr/tree/\(Fixture.commit)",
            "https://huggingface.co/org/tokenizer/tree/\(Fixture.commit)",
        ])
        #expect(status.progress == nil && !status.isInUse && !status.isManaged)
        try await store.download("vad")
        #expect(await store.status(of: "asr")?.size == 607_010)
        #expect(await store.status(of: "vad")?.size == 3_000)
    }
}

@Suite(.timeLimit(.minutes(1))) struct VoiceModelPolicyTests {
    @Test func administratorFolderReplacesDownloads() async throws {
        let fixture = try await Fixture()
        let managed = ManagedSettings(voiceModelDownloadsDisabled: true)
        try fixture.place(fixture.asr, in: fixture.locations.managed.appending(path: "asr"), manifest: false)
        try fixture.place(fixture.vad, in: fixture.locations.managed.appending(path: "vad"), manifest: false)
        let store = fixture.store(managed)
        #expect(!store.canDownload)

        await #expect(throws: VoiceModelFailure.downloadsDisabled) { try await store.download("other") }
        let status = try #require(await store.status(of: "asr"))
        #expect(status.state == .ready && status.isManaged)
        #expect(await store.status(of: "other")?.state == .absent)

        let folder = try await store.acquire("asr")
        #expect(folder == fixture.locations.managed.appending(path: "asr", directoryHint: .isDirectory))
        await store.release("asr")
        // Deleting leaves the administrator's folder alone.
        try await store.delete("asr")
        #expect(fixture.filesMatch(fixture.asr, in: folder))
        #expect(fixture.server.requests.isEmpty && fixture.http.requests.isEmpty)
    }

    @Test func administratorFilesAreCheckedOnFirstUse() async throws {
        let fixture = try await Fixture()
        let folder = fixture.locations.managed.appending(path: "asr")
        try fixture.place(fixture.asr, in: folder, manifest: false)
        try fixture.place(fixture.vad, in: fixture.locations.managed.appending(path: "vad"), manifest: false)
        // Right size, wrong bytes: sizes pass at launch, the checksum does not.
        let vocab = folder.appending(path: "tokenizer/vocab.json")
        try Data(repeating: 7, count: 5_000).write(to: vocab)
        let store = fixture.store(ManagedSettings(voiceModelDownloadsDisabled: true))
        #expect(await store.status(of: "asr")?.state == .ready)

        await #expect(throws: VoiceModelFailure.checksumMismatch("tokenizer/vocab.json")) {
            _ = try await store.acquire("asr")
        }
        let status = await store.status(of: "asr")
        #expect(status?.state == .damaged && status?.isInUse == false)
    }
}

@Suite(.timeLimit(.minutes(1))) struct VoiceNetworkTests {
    @Test func voiceOffMakesNoRequests() async throws {
        let fixture = try await Fixture()
        try fixture.place(fixture.asr, in: fixture.folder("asr"))
        let store = fixture.store(ManagedSettings(voiceDisabled: true))
        #expect(!store.canDownload)
        await #expect(throws: VoiceModelFailure.voiceDisabled) { try await store.download("other") }
        await #expect(throws: VoiceModelFailure.voiceDisabled) { _ = try await store.acquire("asr") }
        _ = await store.statuses
        _ = await store.diskUsage()

        // The app allows no purpose while voice is off; the client refuses before connecting.
        fixture.http.allowed = []
        let request = URLRequest(url: URL(string: fixture.server.base + fixture.weightPath)!)
        await #expect(throws: VoiceHTTP.Failure.blocked(.modelDownload)) {
            _ = try await fixture.http.data(for: request, purpose: .modelDownload)
        }
        let blocked = fixture.store()
        await #expect(throws: VoiceModelFailure.networkBlocked) { try await blocked.download("other") }
        // Closed until the app opens it.
        #expect(VoiceHTTP().allowed.isEmpty && VoiceHTTP.shared.allowed.isEmpty)

        #expect(fixture.http.requests.isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func voiceOnWithALocalModelMakesNoRequests() async throws {
        let fixture = try await Fixture()
        try fixture.place(fixture.asr, in: fixture.folder("asr"))
        try fixture.place(fixture.vad, in: fixture.folder("vad"))
        let store = fixture.store()
        #expect(await store.status(of: "asr")?.state == .ready)
        try await store.download("asr")
        let folder = try await store.acquire("asr")
        _ = try await store.acquire("vad")
        #expect(fixture.filesMatch(fixture.asr, in: folder))
        await store.release("asr")
        await store.release("vad")
        await store.refresh()
        _ = await store.diskUsage()

        #expect(fixture.http.requests.isEmpty)
        #expect(fixture.server.requests.isEmpty)
    }

    /// Voice reaches the network only through `VoiceHTTP`.
    @Test func onlyVoiceHTTPHasASession() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/PerekeyVoice").standardized
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "VoiceHTTP.swift" })
        for file in files where file.lastPathComponent != "VoiceHTTP.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["URLSession", "NSURLConnection", "CFNetwork", "NWConnection", "dataTask("] {
                #expect(!text.contains(word), "\(file.lastPathComponent) uses \(word)")
            }
        }
    }
}
