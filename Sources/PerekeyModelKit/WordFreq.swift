// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A wordfreq list (`large_ru.msgpack.gz`): words by frequency.
///
/// The file is a MessagePack array. Element 0 is a header map
/// `{"format": "cB", "version": 1}`; element i ≥ 1 is the list of words whose
/// frequency is 10^(-i/100), so the Zipf value (log10 of frequency per
/// billion) is 9 − i/100.
public struct WordFreq {
    public struct Entry: Hashable, Sendable {
        public var word: String
        /// log10 of frequency per billion words: "the" is about 7.7.
        public var zipf: Double
    }

    public var entries: [Entry]

    public init(gzipPath path: String) throws {
        try self.init(messagePack: Archive.gunzip(path))
    }

    public init(messagePack data: Data) throws {
        var reader = MessagePackReader(data)
        let top = try reader.read()
        guard case let .array(buckets) = top, let first = buckets.first, case let .map(header) = first,
              header["format"] == .string("cB")
        else { throw MessagePackReader.Failure(description: "not a wordfreq cB list") }
        var entries: [Entry] = []
        for (index, bucket) in buckets.enumerated().dropFirst() {
            guard case let .array(words) = bucket else { continue }
            let zipf = 9 - Double(index) / 100
            for word in words {
                if case let .string(text) = word { entries.append(Entry(word: text, zipf: zipf)) }
            }
        }
        self.entries = entries
    }

    /// The frequency rank stored in the model: `round(zipf · 32)` clamped to
    /// 1…255, so rank 255 is Zipf 8 and the rank 0 means "no frequency known".
    public static func rank(zipf: Double) -> UInt8 {
        UInt8(min(255, max(1, (zipf * 32).rounded())))
    }
}

/// The subset of MessagePack that wordfreq files use.
struct MessagePackReader {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case string(String)
        case array([Value])
        case map([String: Value])
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    private mutating func byte() throws -> UInt8 {
        guard offset < data.endIndex else { throw Failure(description: "msgpack: truncated") }
        let value = data[offset]
        offset += 1
        return value
    }

    private mutating func unsigned(_ bytes: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<bytes { value = value << 8 | UInt64(try byte()) }
        return value
    }

    private mutating func string(_ length: Int) throws -> String {
        guard offset + length <= data.endIndex else { throw Failure(description: "msgpack: truncated string") }
        let text = String(decoding: data[offset..<offset + length], as: UTF8.self)
        offset += length
        return text
    }

    private mutating func array(_ count: Int) throws -> Value {
        var values: [Value] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try read()) }
        return .array(values)
    }

    private mutating func map(_ count: Int) throws -> Value {
        var values: [String: Value] = [:]
        for _ in 0..<count {
            guard case let .string(key) = try read() else { throw Failure(description: "msgpack: non-string key") }
            values[key] = try read()
        }
        return .map(values)
    }

    mutating func read() throws -> Value {
        let marker = try byte()
        switch marker {
        case 0x00...0x7F: return .int(Int64(marker))
        case 0x80...0x8F: return try map(Int(marker & 0x0F))
        case 0x90...0x9F: return try array(Int(marker & 0x0F))
        case 0xA0...0xBF: return .string(try string(Int(marker & 0x1F)))
        case 0xC0: return .null
        case 0xC2: return .bool(false)
        case 0xC3: return .bool(true)
        case 0xCC: return .int(Int64(try unsigned(1)))
        case 0xCD: return .int(Int64(try unsigned(2)))
        case 0xCE: return .int(Int64(try unsigned(4)))
        case 0xCF: return .int(Int64(bitPattern: try unsigned(8)))
        case 0xD0: return .int(Int64(Int8(bitPattern: UInt8(try unsigned(1)))))
        case 0xD1: return .int(Int64(Int16(bitPattern: UInt16(try unsigned(2)))))
        case 0xD2: return .int(Int64(Int32(bitPattern: UInt32(try unsigned(4)))))
        case 0xD3: return .int(Int64(bitPattern: try unsigned(8)))
        case 0xD9: return .string(try string(Int(try unsigned(1))))
        case 0xDA: return .string(try string(Int(try unsigned(2))))
        case 0xDB: return .string(try string(Int(try unsigned(4))))
        case 0xDC: return try array(Int(try unsigned(2)))
        case 0xDD: return try array(Int(try unsigned(4)))
        case 0xDE: return try map(Int(try unsigned(2)))
        case 0xDF: return try map(Int(try unsigned(4)))
        case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: marker)))
        default: throw Failure(description: "msgpack: unsupported marker \(marker)")
        }
    }
}
