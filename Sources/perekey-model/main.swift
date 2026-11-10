// SPDX-License-Identifier: GPL-3.0-or-later
//
// Builds the language model files from the data cache, one per language.
// scripts/build-model.sh wraps it.
//
//   perekey-model --cache <dir> --data <dir> --out <dir> [--languages ru,en,uk]
//   perekey-model pairs --cache <dir> --data <dir> --language ru|en [--sources scripts/fetch-data.sh]
//
// Writes <out>/<language>.pklm. Deterministic: the same inputs give the same
// bytes. Prints the SHA-256 of each file as `shasum -a 256` does, the sizes
// and the build time. A language of `ModelBuild.pairLanguages` takes its
// pair table from <cache>/pairs/<language>.tsv when the file is there.
//
// `pairs` counts the neighbouring words of <cache>/pairs/<language>.txt
// (scripts/wiki-text.py) against this build's dictionary and writes
// <cache>/pairs/<language>.tsv. It first checks that the training files of
// scripts/fetch-data.sh share no file with the held-out ones. Minutes, not
// seconds; scripts/build-pairs.sh runs both steps.

import CryptoKit
import Foundation
import PerekeyCore
import PerekeyModelKit

var cache = ProcessInfo.processInfo.environment["PEREKEY_DATA_CACHE"] ?? ".build/data-cache"
var data = "data"
var out = ".build/model"
var languages = ModelBuild.languages
var language = ""
var sources = "scripts/fetch-data.sh"
var arguments = CommandLine.arguments.dropFirst().makeIterator()
let pairsCommand = CommandLine.arguments.dropFirst().first == "pairs"
if pairsCommand { _ = arguments.next() }
while let argument = arguments.next() {
    switch argument {
    case "--language" where pairsCommand: language = arguments.next() ?? ""
    case "--sources" where pairsCommand: sources = arguments.next() ?? sources
    case "--cache": cache = arguments.next() ?? cache
    case "--data": data = arguments.next() ?? data
    case "--out": out = arguments.next() ?? out
    case "--languages": languages = (arguments.next() ?? "").split(separator: ",").map(String.init)
    default:
        FileHandle.standardError.write(Data(
            "usage: perekey-model --cache <dir> --data <dir> --out <dir> [--languages ru,en,uk]\n       perekey-model pairs --cache <dir> --data <dir> --language ru|en [--sources <fetch-data.sh>]\n".utf8))
        exit(2)
    }
}

let start = ContinuousClock.now
if pairsCommand {
    do {
        guard ModelBuild.pairLanguages.contains(language) else {
            throw ModelBuild.Failure(description: "--language must be one of \(ModelBuild.pairLanguages.sorted().joined(separator: ", "))")
        }
        let directory = "\(cache)/wikipedia-pairs/\(language)"
        let cached = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".parquet") }.sorted().map { "wikipedia-pairs/\(language)/\($0)" }
        try PairSources.check(script: String(contentsOfFile: sources, encoding: .utf8), cachedFiles: cached)

        var known: [UInt64] = []
        _ = try ModelBuild(cache: cache, data: data).run(languages: [language], pairs: false) { _, builder in
            known = builder.knownForms(language: language, minimumRank: Classifier.Options().knownRank)
        }
        let manifest = (try? String(contentsOfFile: "\(cache)/MANIFEST.sha256", encoding: .utf8)) ?? ""
        let training = ModelBuild.trainingFiles(manifest, language: language)
        guard training.count == cached.count else {
            throw ModelBuild.Failure(description: "MANIFEST.sha256 lists \(training.count) training files, the cache holds \(cached.count): run scripts/fetch-data.sh pairs")
        }
        let text = "\(cache)/pairs/\(language).txt"
        let table = try PairTable.count(language: language, sources: training, knownForms: known) { line in
            try TextLines.forEach(path: text, line)
        }
        let path = "\(cache)/pairs/\(language).tsv"
        try table.write(to: path)
        let seconds = (ContinuousClock.now - start).components.seconds
        print("pairs \(language): \(table.tokens) words, \(known.count) known forms, \(table.entries.count) pairs with count and lift enough, \(table.chosen().count) in the model, in \(seconds) s")
        print("wrote \(path)")
    } catch {
        FileHandle.standardError.write(Data("perekey-model pairs: \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
do {
    let report = try ModelBuild(cache: cache, data: data).run(languages: languages)
    let directory = URL(fileURLWithPath: out, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for note in report.notes { print(note) }
    var hashes: [String] = []
    for file in report.files {
        let name = "\(file.language).pklm"
        // The reader of the app must take the file: its checks are strict (every section's buckets
        // cut the entries from the first to the last), and a file it refuses is no build.
        let reader = try LanguageModel(bytes: file.bytes)
        guard reader.language(file.language) != nil else {
            throw ModelBuild.Failure(description: "\(name): the reader finds no \(file.language) in it")
        }
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
