// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a run in a real app records besides the files of every run: the text of each case, or its hash
/// where the words may not be shown. The comparison with the machine reads it (`app.json` of the run folder).
public struct AppRun: Codable, Equatable, Sendable {
    public struct Played: Codable, Equatable, Sendable {
        public var id: String
        public var split: String
        /// The id of the input source in force at the end.
        public var layout: String
        public var sha256: String
        /// The text of the field; absent for a case of the part `test` unless the run reveals it (rule 2.8).
        public var text: String?
    }

    /// The bundle id of the app.
    public var app: String
    /// Cases left out, by the reason (`AppSupport`).
    public var skipped: [String: Int]
    public var played: [Played]
    /// Why the run stopped before its last case; nil when it did not.
    public var aborted: String?

    public init(app: String, skipped: [String: Int], played: [Played], aborted: String? = nil) {
        self.app = app
        self.skipped = skipped
        self.played = played
        self.aborted = aborted
    }

    public static let fileName = "app.json"

    public static func played(_ item: EvalCase, _ result: RunResult, reveal: Bool) -> Played {
        Played(id: item.id, split: item.split.rawValue, layout: result.layout.rawValue,
               sha256: Runner.sha256(Data(result.text.utf8)),
               text: item.split == .test && !reveal ? nil : result.text)
    }

    public func write(to directory: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
        try text.write(toFile: (directory as NSString).appendingPathComponent(Self.fileName), atomically: true, encoding: .utf8)
    }

    public static func read(from directory: String) throws -> AppRun {
        let path = (directory as NSString).appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw EvalError.input("\(path): no such file; --app-run is a run folder of `perekey-e2e play`")
        }
        return try JSONDecoder().decode(AppRun.self, from: data)
    }
}
