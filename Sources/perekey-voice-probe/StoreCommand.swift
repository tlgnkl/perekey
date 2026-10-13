// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyVoice
import PerekeyVoiceCore

/// `store …`: the app's `VoiceModelStore` against the real Hugging Face, in a
/// folder of its own (`PEREKEY_VOICE_MODELS`), with a CoreML cache beside it.
enum StoreCommand {
    static func run(_ arguments: [String]) async throws {
        guard let root = ProcessInfo.processInfo.environment["PEREKEY_VOICE_MODELS"] else {
            throw ProbeError.message("set PEREKEY_VOICE_MODELS to a scratch folder")
        }
        let models = URL(filePath: root, directoryHint: .isDirectory)
        let locations = VoiceModelLocations(
            models: models, managed: models.appending(path: "../managed").standardized,
            coreMLCache: models.appending(path: "../coreml-cache").standardized)
        let store = VoiceModelStore(locations: locations, managed: ManagedSettings())
        let ids = Array(arguments.dropFirst())
        switch arguments.first {
        case "status":
            await printStatus(store)
        case "download":
            let watcher = Task { await watch(store) }
            defer { watcher.cancel() }
            for id in ids {
                let start = ContinuousClock.now
                try await store.download(id)
                print("\(id): ready in \(ContinuousClock.now - start)")
            }
        case "verify":
            for id in ids {
                guard let entry = ModelCatalog.entry(id: id), let folder = await store.folder(of: id) else {
                    throw ProbeError.message("\(id) is not ready")
                }
                try VoiceModelStoreChecks.verify(entry, in: folder)
                print("\(id): every SHA-256 matches")
            }
        case "hold-delete":
            // An engine holds the model: deleting it must fail and leave the files.
            for id in ids {
                let folder = try await store.acquire(id)
                do {
                    try await store.delete(id)
                    print("\(id): deleted while held — WRONG")
                } catch {
                    print("\(id): delete while held refused: \(error)")
                }
                print("\(id): still ready: \(await store.status(of: id)?.state == .ready), folder \(FileManager.default.fileExists(atPath: folder.path))")
                await store.release(id)
            }
        case "delete":
            for id in ids { try await store.delete(id) }
        case "delete-all":
            print("kept: \(try await store.deleteAll())")
        default:
            throw ProbeError.message("store status | download <id>... | verify <id>... | hold-delete <id>... | delete <id>... | delete-all")
        }
        if arguments.first != "status" { await printStatus(store) }
        print("requests: \(VoiceHTTP.shared.requests.count), hosts: \(Set(VoiceHTTP.shared.requests.map(\.host)).sorted())")
    }

    private static func printStatus(_ store: VoiceModelStore) async {
        for status in await store.statuses {
            print("\(status.id)\t\(status.state)\t\(status.size)\(status.failure.map { "\t\($0)" } ?? "")")
        }
        let usage = await store.diskUsage()
        print("disk: models \(usage.models), cache \(usage.cache)")
    }

    /// Prints progress every 5 %.
    private static func watch(_ store: VoiceModelStore) async {
        var shown: [String: Int] = [:]
        for await statuses in await store.updates() {
            for status in statuses {
                guard case .downloading = status.state, let progress = status.progress else { continue }
                let step = Int(progress * 20)
                if shown[status.id] != step {
                    shown[status.id] = step
                    print("  \(status.id) \(step * 5)%")
                }
            }
        }
    }
}

/// Full checksum pass, outside the store, for the manual check.
enum VoiceModelStoreChecks {
    static func verify(_ entry: VoiceModelEntry, in folder: URL) throws {
        for source in entry.sources {
            for file in source.files {
                let hash = try Downloader.sha256(of: folder.appending(path: file.path))
                guard hash == file.sha256 else { throw ProbeError.message("\(file.path): \(hash)") }
            }
        }
    }
}
