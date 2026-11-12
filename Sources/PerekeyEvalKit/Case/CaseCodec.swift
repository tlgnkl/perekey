// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore
import PerekeyDesk

/// Reads and writes cases, one JSON object per line: UTF-8, sorted keys, no
/// spaces, so the bytes are stable. Reading is strict: an unknown field, an
/// unknown step or another format version is an error.
public enum CaseCodec {
    public struct ReadError: Error, CustomStringConvertible {
        public var file: String
        public var line: Int
        public var message: String

        public var description: String { "\(file):\(line): \(message)" }
    }

    /// The canonical JSON of any value: sorted keys, slashes as they are.
    public static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func line(_ item: EvalCase) throws -> String {
        try json(item)
    }

    public static func decode(_ line: String) throws -> EvalCase {
        try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
    }

    /// Every case of a `.jsonl` text; empty lines are skipped.
    public static func read(_ text: String, file: String = "-") throws -> [EvalCase] {
        var cases: [EvalCase] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.isEmpty
        {
            do {
                cases.append(try decode(String(line)))
            } catch let error as DecodingError {
                throw ReadError(file: file, line: index + 1, message: describe(error))
            } catch {
                throw ReadError(file: file, line: index + 1, message: "\(error)")
            }
        }
        return cases
    }

    public static func read(file path: String) throws -> [EvalCase] {
        var cases: [EvalCase] = []
        try forEach(file: path) { cases.append($0) }
        return cases
    }

    /// Every case of a `.jsonl` file, one at a time: the file is read in pieces, so a corpus of
    /// gigabytes is never in memory at once.
    public static func forEach(file path: String, _ body: (EvalCase) throws -> Void) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        var pending = Data()
        var line = 0
        func decodeLine(_ bytes: Data) throws {
            line += 1
            guard !bytes.isEmpty else { return }
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw ReadError(file: path, line: line, message: "not UTF-8")
            }
            let item: EvalCase
            do {
                item = try decode(text)
            } catch let error as DecodingError {
                throw ReadError(file: path, line: line, message: describe(error))
            } catch {
                throw ReadError(file: path, line: line, message: "\(error)")
            }
            try body(item)
        }
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                try decodeLine(pending[start..<newline])
                start = newline + 1
            }
            pending = Data(pending[start...])
        }
        try decodeLine(pending)
    }

    public static func write(_ cases: [EvalCase]) throws -> String {
        try cases.map { try line($0) + "\n" }.joined()
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case let .dataCorrupted(context): return "\(path(context)): \(context.debugDescription)"
        case let .keyNotFound(key, context): return "\(path(context)): missing field \(key.stringValue)"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}

/// A coding key of any name: the strict readers list the keys they got.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Fails on a key outside `known`.
    func onlyKeys(_ known: Set<String>, in what: String) throws {
        for key in allKeys where !known.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                   debugDescription: "unknown field \(key.stringValue) in \(what)")
        }
    }

    func required<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try decode(type, forKey: AnyKey(name))
    }

    func optional<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        try decodeIfPresent(type, forKey: AnyKey(name))
    }
}

extension EvalCase: Codable {
    private static let fields: Set<String> = [
        "v", "id", "suite", "scenario", "split", "epoch", "layouts", "start", "env", "warmup", "script", "want",
        "tokens", "scoring", "checks", "fold", "tags", "meta",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(Self.fields, in: "case")
        v = try c.required(Int.self, "v")
        guard v == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: AnyKey("v"), in: c,
                                                   debugDescription: "format version \(v), this reader knows \(Self.version)")
        }
        id = try c.required(String.self, "id")
        suite = try c.required(String.self, "suite")
        scenario = try c.required(String.self, "scenario")
        split = try c.required(Split.self, "split")
        epoch = try c.optional(Int.self, "epoch")
        layouts = try c.required([String].self, "layouts")
        start = try c.required(String.self, "start")
        env = try c.optional(Env.self, "env")
        warmup = try c.optional([Step].self, "warmup")
        script = try c.required([Step].self, "script")
        want = try c.required(String.self, "want")
        tokens = try c.optional([TokenSpec].self, "tokens")
        scoring = try c.optional(Scoring.self, "scoring")
        checks = try c.optional([Check].self, "checks")
        fold = try c.optional([Fold].self, "fold")
        tags = try c.optional([String].self, "tags")
        meta = try c.optional([String: JSONValue].self, "meta")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(v, forKey: AnyKey("v"))
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(suite, forKey: AnyKey("suite"))
        try c.encode(scenario, forKey: AnyKey("scenario"))
        try c.encode(split, forKey: AnyKey("split"))
        try c.encodeIfPresent(epoch, forKey: AnyKey("epoch"))
        try c.encode(layouts, forKey: AnyKey("layouts"))
        try c.encode(start, forKey: AnyKey("start"))
        try c.encodeIfPresent(env, forKey: AnyKey("env"))
        try c.encodeIfPresent(warmup, forKey: AnyKey("warmup"))
        try c.encode(script, forKey: AnyKey("script"))
        try c.encode(want, forKey: AnyKey("want"))
        try c.encodeIfPresent(tokens, forKey: AnyKey("tokens"))
        try c.encodeIfPresent(scoring, forKey: AnyKey("scoring"))
        try c.encodeIfPresent(checks, forKey: AnyKey("checks"))
        try c.encodeIfPresent(fold, forKey: AnyKey("fold"))
        try c.encodeIfPresent(tags, forKey: AnyKey("tags"))
        try c.encodeIfPresent(meta, forKey: AnyKey("meta"))
    }
}

extension Env: Codable {
    private static let fields: Set<String> = [
        "app", "mode", "settings", "field", "pace", "lag", "prior", "exceptions", "alwaysFix", "secureInput",
    ]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(Self.fields, in: "env")
        app = try c.optional(String.self, "app")
        mode = try c.optional(AppMode.self, "mode")
        settings = try c.optional(String.self, "settings")
        if let name = try c.optional(String.self, "field") {
            guard let kind = FieldKind(rawValue: name) else {
                throw DecodingError.dataCorruptedError(forKey: AnyKey("field"), in: c,
                                                       debugDescription: "unknown field kind \(name)")
            }
            field = kind
        }
        pace = try c.optional(Pace.self, "pace")
        lag = try c.optional(Int.self, "lag")
        prior = try c.optional([String: Double].self, "prior")
        exceptions = try c.optional([String].self, "exceptions")
        alwaysFix = try c.optional([String: String].self, "alwaysFix")
        secureInput = try c.optional(Bool.self, "secureInput")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(app, forKey: AnyKey("app"))
        try c.encodeIfPresent(mode, forKey: AnyKey("mode"))
        try c.encodeIfPresent(settings, forKey: AnyKey("settings"))
        try c.encodeIfPresent(field?.rawValue, forKey: AnyKey("field"))
        try c.encodeIfPresent(pace, forKey: AnyKey("pace"))
        try c.encodeIfPresent(lag, forKey: AnyKey("lag"))
        try c.encodeIfPresent(prior, forKey: AnyKey("prior"))
        try c.encodeIfPresent(exceptions, forKey: AnyKey("exceptions"))
        try c.encodeIfPresent(alwaysFix, forKey: AnyKey("alwaysFix"))
        try c.encodeIfPresent(secureInput, forKey: AnyKey("secureInput"))
    }
}

extension Step: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let keys = Set(c.allKeys.map(\.stringValue))
        func only(_ known: Set<String>, _ name: String) throws { try c.onlyKeys(known, in: "step \(name)") }
        if keys.contains("type") {
            try only(["type", "on"], "type")
            self = try .type(c.required(String.self, "type"), on: c.required(String.self, "on"))
        } else if keys.contains("layout") {
            try only(["layout"], "layout")
            self = try .layout(c.required(String.self, "layout"))
        } else if keys.contains("hotkey") {
            try only(["hotkey"], "hotkey")
            self = try .hotkey(c.required(HotkeyName.self, "hotkey"))
        } else if keys.contains("key") {
            try only(["key", "n", "mods"], "key")
            self = try .key(c.required(KeyName.self, "key"), n: c.optional(Int.self, "n"),
                            mods: c.optional([ModName].self, "mods"))
        } else if keys.contains("click") {
            try only(["click"], "click")
            if let position = try? c.decode(Int.self, forKey: AnyKey("click")) {
                self = .click(.position(position))
            } else {
                switch try c.required(String.self, "click") {
                case "start": self = .click(.start)
                case "end": self = .click(.end)
                case "hint": self = .click(.hint)
                case let other:
                    throw DecodingError.dataCorruptedError(forKey: AnyKey("click"), in: c,
                                                           debugDescription: "unknown click target \(other)")
                }
            }
        } else if keys.contains("focus") {
            try only(["focus"], "focus")
            let focus = try c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("focus"))
            try focus.onlyKeys(["app", "secure", "known"], in: "focus")
            self = try .focus(FocusSpec(app: focus.optional(String.self, "app"),
                                        secure: focus.optional(Bool.self, "secure"),
                                        known: focus.optional(Bool.self, "known")))
        } else if keys.contains("mode") {
            try only(["mode"], "mode")
            self = try .mode(c.required(AppMode.self, "mode"))
        } else if keys.contains("capsLock") {
            try only(["capsLock"], "capsLock")
            self = try .capsLock(c.required(Bool.self, "capsLock"))
        } else if keys.contains("select") {
            try only(["select"], "select")
            self = try .select(c.required(Int.self, "select"))
        } else if keys.contains("secureInput") {
            try only(["secureInput"], "secureInput")
            self = try .secureInput(c.required(Bool.self, "secureInput"))
        } else if keys.contains("wait") {
            try only(["wait"], "wait")
            self = try .wait(c.required(Double.self, "wait"))
        } else if keys.contains("pace") {
            try only(["pace"], "pace")
            self = try .pace(c.required(Pace.self, "pace"))
        } else if keys.contains("undo") {
            try only(["undo"], "undo")
            self = try .undo(c.required(UndoSpec.self, "undo"))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown step \(keys.sorted())"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case let .type(text, on):
            try c.encode(text, forKey: AnyKey("type"))
            try c.encode(on, forKey: AnyKey("on"))
        case let .layout(name):
            try c.encode(name, forKey: AnyKey("layout"))
        case let .hotkey(name):
            try c.encode(name, forKey: AnyKey("hotkey"))
        case let .key(name, n, mods):
            try c.encode(name, forKey: AnyKey("key"))
            try c.encodeIfPresent(n, forKey: AnyKey("n"))
            try c.encodeIfPresent(mods, forKey: AnyKey("mods"))
        case let .click(target):
            switch target {
            case .start: try c.encode("start", forKey: AnyKey("click"))
            case .end: try c.encode("end", forKey: AnyKey("click"))
            case .hint: try c.encode("hint", forKey: AnyKey("click"))
            case let .position(position): try c.encode(position, forKey: AnyKey("click"))
            }
        case let .focus(focus):
            try c.encode(focus, forKey: AnyKey("focus"))
        case let .mode(mode):
            try c.encode(mode, forKey: AnyKey("mode"))
        case let .capsLock(on):
            try c.encode(on, forKey: AnyKey("capsLock"))
        case let .select(count):
            try c.encode(count, forKey: AnyKey("select"))
        case let .secureInput(on):
            try c.encode(on, forKey: AnyKey("secureInput"))
        case let .wait(seconds):
            try c.encode(seconds, forKey: AnyKey("wait"))
        case let .pace(pace):
            try c.encode(pace, forKey: AnyKey("pace"))
        case let .undo(spec):
            try c.encode(spec, forKey: AnyKey("undo"))
        }
    }
}

extension TokenSpec: Codable {
    private static let fields: Set<String> = ["t", "lang", "err", "accept", "tags", "w"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(Self.fields, in: "token")
        t = try c.required(String.self, "t")
        lang = try c.required(String.self, "lang")
        err = try c.required(TokenError.self, "err")
        accept = try c.optional([String].self, "accept")
        tags = try c.optional([String].self, "tags")
        w = try c.optional(Double.self, "w")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(t, forKey: AnyKey("t"))
        try c.encode(lang, forKey: AnyKey("lang"))
        try c.encode(err, forKey: AnyKey("err"))
        try c.encodeIfPresent(accept, forKey: AnyKey("accept"))
        try c.encodeIfPresent(tags, forKey: AnyKey("tags"))
        try c.encodeIfPresent(w, forKey: AnyKey("w"))
    }
}

extension Check: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        try c.onlyKeys(["layout", "corrections", "undone"], in: "check")
        guard c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a check has exactly one field"))
        }
        if let layout = try c.optional(String.self, "layout") {
            self = .layout(layout)
        } else if let count = try c.optional(Int.self, "corrections") {
            self = .corrections(count)
        } else {
            self = try .undone(c.required(Int.self, "undone"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case let .layout(name): try c.encode(name, forKey: AnyKey("layout"))
        case let .corrections(count): try c.encode(count, forKey: AnyKey("corrections"))
        case let .undone(count): try c.encode(count, forKey: AnyKey("undone"))
        }
    }
}
