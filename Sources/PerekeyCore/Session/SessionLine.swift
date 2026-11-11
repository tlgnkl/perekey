// SPDX-License-Identifier: GPL-3.0-or-later

/// One line of a `.pksession` file: JSON Lines, one object with one key
/// (docs/classifier.md, «Замер на живых сессиях»):
///
///     {"header":{"format":"perekey-session","version":1,"perekey":"0.3.0","build":"312","time":1762780000}}
///     {"snapshot":{"machine":{…},"classifier":{"languages":["en","ru"],"options":{…}}}}
///     {"step":{"event":{…},"output":{"disposition":{"pass":{}},"effects":[]}}}
///     {"gap":"secureField"}
///
/// The header comes first. A snapshot starts a segment, and the steps after
/// it are the events the machine handled, with what it answered. A gap
/// ends the segment: what happened meanwhile is not in the file, and the
/// next segment starts with a snapshot of its own.
public enum SessionLine: Hashable, Sendable, Codable {
    case header(SessionHeader)
    case snapshot(SessionSnapshot)
    case step(SessionStep)
    case gap(SessionGap)

    private enum CodingKeys: String, CodingKey {
        case header, snapshot, step, gap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "a line holds one of header, snapshot, step, gap"))
        }
        switch key {
        case .header: self = try .header(container.decode(SessionHeader.self, forKey: key))
        case .snapshot: self = try .snapshot(container.decode(SessionSnapshot.self, forKey: key))
        case .step: self = try .step(container.decode(SessionStep.self, forKey: key))
        case .gap: self = try .gap(container.decode(SessionGap.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .header(header): try container.encode(header, forKey: .header)
        case let .snapshot(snapshot): try container.encode(snapshot, forKey: .snapshot)
        case let .step(step): try container.encode(step, forKey: .step)
        case let .gap(gap): try container.encode(gap, forKey: .gap)
        }
    }
}

/// The first line of a session file.
public struct SessionHeader: Hashable, Sendable, Codable {
    public static let format = "perekey-session"
    /// The version of the file format, not of Perekey. A reader refuses a
    /// version it does not know.
    public static let version = 1

    public var format: String
    public var version: Int
    /// The version and the build of Perekey that wrote the file.
    public var perekey: String
    public var build: String
    /// When the file was started, in seconds since 1970.
    public var time: Double

    public init(perekey: String, build: String, time: Double) {
        format = Self.format
        version = Self.version
        self.perekey = perekey
        self.build = build
        self.time = time
    }
}

/// What a segment starts from: the machine's state and its classifier.
public struct SessionSnapshot: Hashable, Sendable, Codable {
    public var machine: MachineSnapshot
    public var classifier: ClassifierSpec?

    public init(machine: MachineSnapshot, classifier: ClassifierSpec?) {
        self.machine = machine
        self.classifier = classifier
    }

    /// The snapshot of a machine at a quiet point (`InputMachine.isQuiet`).
    public init(_ machine: InputMachine) {
        self.init(machine: machine.snapshot, classifier: machine.classifier.map(ClassifierSpec.init))
    }
}

/// One event the machine handled, and what it answered.
public struct SessionStep: Hashable, Sendable, Codable {
    public var event: RecordedEvent
    public var output: OutputDigest

    public init(event: RecordedEvent, output: OutputDigest) {
        self.event = event
        self.output = output
    }
}

/// Why the recording stopped for a while. Keys typed then are not written.
public enum SessionGap: String, Hashable, Sendable, Codable {
    /// A password field had focus.
    case secureField
    /// Secure Input was on.
    case secureInput
    /// The focus was in an app on the list of apps never recorded.
    case excludedApp
    /// The buffer of the recorder was full: the disk did not keep up.
    case overflow
    /// The focus was not known: no app named yet, or accessibility did not
    /// say what is focused. It may be a password field.
    case unknownFocus
    /// The file could not be created or written (disk full, folder gone).
    /// Never in a file: there is none to take it. It is the buffer's reason
    /// for a new file at the next quiet point.
    case writeFailed
}
