// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dumps installed keyboard layouts as JSON test fixtures.
//
//   swift run perekey-layout-dump <output dir> [layout ID…]
//
// Without layout IDs it dumps the set the tests use.

import Foundation
import PerekeyCore
import PerekeyInput

let defaultIDs = [
    "com.apple.keylayout.US",
    "com.apple.keylayout.ABC",
    "com.apple.keylayout.USExtended",
    "com.apple.keylayout.Russian",
    "com.apple.keylayout.RussianWin",
    "com.apple.keylayout.Ukrainian-PC",
]

let arguments = CommandLine.arguments.dropFirst()
guard let output = arguments.first else {
    FileHandle.standardError.write(Data("usage: perekey-layout-dump <output dir> [layout ID…]\n".utf8))
    exit(2)
}
let ids = arguments.count > 1 ? Array(arguments.dropFirst()) : defaultIDs

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
var failed = false
for id in ids {
    guard let map = MainActor.assumeIsolated({ LayoutReader.installedLayout(LayoutID(rawValue: id)) }) else {
        FileHandle.standardError.write(Data("not installed or has no key table: \(id)\n".utf8))
        failed = true
        continue
    }
    let name = id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    let url = URL(fileURLWithPath: output).appendingPathComponent("\(name).json")
    try encoder.encode(map).write(to: url)
    print(url.path)
}
exit(failed ? 1 : 0)
