// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// A session file read whole: the header and the segments
/// (docs/classifier.md, «Замер на живых сессиях»).
public struct Session: Sendable {
    public var header: SessionHeader
    public var segments: [SessionSegment]
    /// The last line was cut off, as when the app stopped while writing it,
    /// and was left out.
    public var droppedTail: Bool
}

/// A snapshot and the steps after it, up to a gap or the end of the file.
public struct SessionSegment: Sendable {
    public var snapshot: SessionSnapshot
    public var steps: [SessionStep]
    /// The line of each step in the file, from 1.
    public var lines: [Int]
    /// The gap that ended the segment; nil at the end of the file.
    public var gap: SessionGap?

    public init(snapshot: SessionSnapshot, steps: [SessionStep] = [], lines: [Int] = [], gap: SessionGap? = nil) {
        self.snapshot = snapshot
        self.steps = steps
        self.lines = lines
        self.gap = gap
    }
}

public enum SessionFileError: Error, CustomStringConvertible, Equatable {
    case empty
    case unreadable(line: Int, reason: String)
    case notASession(format: String)
    case unsupportedVersion(Int)
    case noHeader(line: Int)
    case secondHeader(line: Int)
    case stepWithoutSnapshot(line: Int)

    public var description: String {
        switch self {
        case .empty:
            "the file is empty"
        case let .unreadable(line, reason):
            "line \(line) is not a session line: \(reason)"
        case let .notASession(format):
            "line 1: not a Perekey session (format \"\(format)\")"
        case let .unsupportedVersion(version):
            "line 1: version \(version) of the session format; this reader knows version \(SessionHeader.version)"
        case let .noHeader(line):
            "line \(line): the file must start with its header"
        case let .secondHeader(line):
            "line \(line): a second header"
        case let .stepWithoutSnapshot(line):
            "line \(line): an event outside a segment; a segment starts with a snapshot"
        }
    }
}

public enum SessionFile {
    /// The file name extension: `2026-11-10-1.pksession`.
    public static let fileExtension = "pksession"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf",
                                                                       negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf",
                                                                         negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// The lines as a file: one JSON object per line, each ended by "\n".
    public static func data(_ lines: [SessionLine]) throws -> Data {
        let encoder = encoder()
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        return data
    }

    public static func read(path: String) throws -> Session {
        try read(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Reads a file and checks its order: the header first, then segments.
    /// A last line without its "\n" that does not parse was cut off while
    /// written: it is dropped (`Session.droppedTail`). Any other broken
    /// line is an error that names it.
    public static func read(_ data: Data) throws -> Session {
        guard !data.isEmpty else { throw SessionFileError.empty }
        let decoder = decoder()
        var chunks = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let complete = data.last == 0x0A
        if complete { chunks.removeLast() }
        guard !chunks.isEmpty else { throw SessionFileError.empty }
        var header: SessionHeader?
        var segments: [SessionSegment] = []
        var open: SessionSegment?
        var droppedTail = false
        for (index, chunk) in chunks.enumerated() {
            let number = index + 1
            let line: SessionLine
            do {
                line = try decoder.decode(SessionLine.self, from: Data(chunk))
            } catch {
                if index == chunks.count - 1, !complete, number > 1 {
                    droppedTail = true
                    break
                }
                throw SessionFileError.unreadable(line: number, reason: Self.reason(error))
            }
            switch line {
            case let .header(found):
                guard number == 1 else { throw SessionFileError.secondHeader(line: number) }
                guard found.format == SessionHeader.format else { throw SessionFileError.notASession(format: found.format) }
                guard found.version == SessionHeader.version else {
                    throw SessionFileError.unsupportedVersion(found.version)
                }
                header = found
            case _ where header == nil:
                throw SessionFileError.noHeader(line: number)
            case let .snapshot(snapshot):
                if let open { segments.append(open) }
                open = SessionSegment(snapshot: snapshot)
            case let .step(step):
                guard open != nil else { throw SessionFileError.stepWithoutSnapshot(line: number) }
                open?.steps.append(step)
                open?.lines.append(number)
            case let .gap(gap):
                if var ended = open {
                    ended.gap = gap
                    segments.append(ended)
                }
                open = nil
            }
        }
        if let open { segments.append(open) }
        guard let header else { throw SessionFileError.empty }
        return Session(header: header, segments: segments, droppedTail: droppedTail)
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case let DecodingError.dataCorrupted(context), let DecodingError.keyNotFound(_, context),
             let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        default:
            return "\(error)"
        }
    }
}
