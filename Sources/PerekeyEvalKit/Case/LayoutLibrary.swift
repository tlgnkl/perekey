// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// The layout snapshots of eval/layouts/, by file name: "ABC", "Russian".
public struct LayoutLibrary: Sendable {
    public let maps: [String: LayoutMap]

    public init(maps: [String: LayoutMap]) {
        self.maps = maps
    }

    /// Every `<name>.json` of the directory.
    public init(directory: String) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".json") }.sorted()
        var maps: [String: LayoutMap] = [:]
        for name in names {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            maps[String(name.dropLast(5))] = try JSONDecoder().decode(LayoutMap.self, from: Data(contentsOf: url))
        }
        self.maps = maps
    }

    public subscript(name: String) -> LayoutMap? { maps[name] }

    /// The maps of a case's `layouts`, in its order.
    public func maps(of item: EvalCase) throws -> [LayoutMap] {
        try item.layouts.map { name in
            guard let map = maps[name] else { throw EvalError.input("unknown layout \(name) in \(item.id)") }
            return map
        }
    }

    /// The stroke that types this character in the layout, if it takes no
    /// ⌥ and no Caps Lock: format v1 types nothing else.
    public static func printableStroke(_ character: Character, in map: LayoutMap) -> KeyStroke? {
        guard let stroke = map.stroke(for: character),
              stroke.modifiers.isDisjoint(with: [.option, .capsLock]),
              map.text(for: stroke) == String(character)
        else { return nil }
        return stroke
    }
}

/// Errors of the bench's input: a bad case, file or argument (exit status 2).
public enum EvalError: Error, CustomStringConvertible, Equatable {
    case input(String)

    public var description: String {
        switch self {
        case let .input(message): message
        }
    }
}
