// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dev tool: downloads, loads and measures speech models outside the app.

import FluidAudio
import Foundation

// Before any FluidAudio call: a failed model load must never delete or download.
ModelHub.offlineMode = true

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print(
        """
        usage: perekey-voice-probe
          download [id...]            fetch models into ~/Library/Caches/perekey-voice-probe
          remote <repo> <commit> [n]  sizes of a repository tree, grouped by n path components
          catalog <ModelCatalogData.swift>
          recognize <id> <wav>...     text each file gets
          measure <id> <wav>          load time, memory, transcription time (JSON)
          load-check <id> [wav]       MLModel(contentsOf:) for every .mlmodelc
          offline-check <scratch> [--online]  corrupted .mlmodelc with offlineMode on
          net-control                 one HTTPS request, to test the sampler
          store <command> [id...]     the app's model store in $PEREKEY_VOICE_MODELS
          speech                      Apple Speech locales
        """)
    exit(2)
}

guard let command = arguments.first else { usage() }
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "download":
        let models = rest.isEmpty ? ProbeModels.all : rest.compactMap(ProbeModels.find)
        for model in models {
            print("download \(model.id)")
            try await Downloader.download(model)
        }
    case "remote":
        guard rest.count >= 2 else { usage() }
        let depth = rest.count > 2 ? Int(rest[2]) ?? 1 : 1
        var sizes: [String: (bytes: Int64, files: Int)] = [:]
        for entry in try await Downloader.list(repo: rest[0], commit: rest[1]) {
            let key = entry.path.split(separator: "/").prefix(depth).joined(separator: "/")
            sizes[key, default: (0, 0)].bytes += entry.size ?? 0
            sizes[key, default: (0, 0)].files += 1
        }
        for key in sizes.keys.sorted() where sizes[key]!.bytes > 0 {
            print("\(key)\t\(sizes[key]!.bytes)\t\(sizes[key]!.files)")
        }
    case "catalog":
        guard let output = rest.first else { usage() }
        try Commands.catalog(output: output)
    case "recognize":
        guard let id = rest.first else { usage() }
        try await Commands.recognize(id: id, files: Array(rest.dropFirst()))
    case "measure":
        guard rest.count == 2 else { usage() }
        try await Commands.measure(id: rest[0], file: rest[1])
    case "load-check":
        guard let id = rest.first else { usage() }
        try await Commands.loadCheck(id: id, file: rest.count > 1 ? rest[1] : nil)
    case "offline-check":
        guard let scratch = rest.first else { usage() }
        try await Commands.offlineCheck(scratch: scratch, online: rest.contains("--online"))
    case "net-control":
        try await Commands.netControl()
    case "store":
        try await StoreCommand.run(rest)
    case "speech":
        await Commands.appleSpeech()
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
