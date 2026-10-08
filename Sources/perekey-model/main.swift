// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the language model from the data cache. scripts/build-model.sh wraps it.
//
//   perekey-model --cache <dir> --data <dir> --out <file>
//
// Deterministic: the same inputs give the same bytes. Prints the SHA-256 of
// the output, the size and the build time.

import CryptoKit
import Foundation
import PerekeyModelKit

var cache = ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
var data = "data"
var out = ".build/model/perekey.model"
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--cache": cache = arguments.next() ?? cache
    case "--data": data = arguments.next() ?? data
    case "--out": out = arguments.next() ?? out
    default:
        FileHandle.standardError.write(Data("usage: perekey-model --cache <dir> --data <dir> --out <file>\n".utf8))
        exit(2)
    }
}

let start = ContinuousClock.now
do {
    let report = try ModelBuild(cache: cache, data: data).run()
    let url = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(report.bytes).write(to: url)
    for note in report.notes { print(note) }
    let digest = SHA256.hash(data: Data(report.bytes)).map { String(format: "%02x", $0) }.joined()
    let seconds = (ContinuousClock.now - start).components.seconds
    print("wrote \(out): \(report.bytes.count / 1024) KB in \(seconds) s")
    print("sha256 \(digest)")
} catch {
    FileHandle.standardError.write(Data("perekey-model: \(error)\n".utf8))
    exit(1)
}
