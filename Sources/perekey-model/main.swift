// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the language model files from the data cache, one per language.
// scripts/build-model.sh wraps it.
//
//   perekey-model --cache <dir> --data <dir> --out <dir> [--languages ru,en,uk]
//
// Writes <out>/<language>.pklm. Deterministic: the same inputs give the same
// bytes. Prints the SHA-256 of each file as `shasum -a 256` does, the sizes
// and the build time.

import CryptoKit
import Foundation
import PerekeyModelKit

var cache = ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
var data = "data"
var out = ".build/model"
var languages = ModelBuild.languages
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--cache": cache = arguments.next() ?? cache
    case "--data": data = arguments.next() ?? data
    case "--out": out = arguments.next() ?? out
    case "--languages": languages = (arguments.next() ?? "").split(separator: ",").map(String.init)
    default:
        FileHandle.standardError.write(Data(
            "usage: perekey-model --cache <dir> --data <dir> --out <dir> [--languages ru,en,uk]\n".utf8))
        exit(2)
    }
}

let start = ContinuousClock.now
do {
    let report = try ModelBuild(cache: cache, data: data).run(languages: languages)
    let directory = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for note in report.notes { print(note) }
    var hashes: [String] = []
    for file in report.files {
        let name = "\(file.language).pklm"
        try Data(file.bytes).write(to: directory.appendingPathComponent(name))
        let digest = SHA256.hash(data: Data(file.bytes)).map { String(format: "%02x", $0) }.joined()
        print("wrote \(name): \(file.bytes.count / 1024) KB")
        hashes.append("\(digest)  \(name)")
    }
    let seconds = (ContinuousClock.now - start).components.seconds
    print("built \(report.files.count) files in \(out) in \(seconds) s")
    for line in hashes { print("sha256 \(line)") }
} catch {
    FileHandle.standardError.write(Data("perekey-model: \(error)\n".utf8))
    exit(1)
}
