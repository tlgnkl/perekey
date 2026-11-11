// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import PerekeyCore

/// The tap thread's half of the typing recorder (CONTRIBUTING.md, «Recording
/// typing for the measure»): what the machine handled, kept in memory until
/// `SessionRecorder` takes it to disk on a queue of its own.
///
/// Only in a build with `PEREKEY_RECORD`. Per event the tap thread appends a
/// value to an array that has room for it: the event and the output as the
/// machine has them. Turning them into session lines (`RecordedEvent`,
/// `OutputDigest`), encoding and writing happen on the recorder's queue. The
/// array is handed over every `Options.batch` entries or when the engine's
/// timer asks (once a second), and a fresh one is made for the next batch:
/// one allocation per batch, none per event. A segment start copies the
/// machine's state (`MachineSnapshot`); that happens after a gap, at the
/// start and once a day, not while typing goes on.
///
/// What is never recorded: while the focus is a password field, while Secure
/// Input is on, while the focus is in an app of `excludedApps`, the buffer
/// writes one `gap` line and nothing more, not even the events that are not
/// keys. The segment ends there. A new one starts with a snapshot at the
/// first quiet point (`InputMachine.isQuiet`) after the reason is gone, so a
/// replay can start from it. The same happens when the writer falls behind:
/// past `Options.limit` entries the buffer writes `gap(overflow)`, and typing
/// is never slowed down.
public struct RecordingBuffer {
    public struct Options: Sendable {
        /// Entries handed to the recorder at once, as plan 6.3 asks. A key
        /// press and release are two events, so 256 entries are about 25
        /// words of typing; the engine's timer hands over a smaller batch
        /// after a second. The cost per event: `PEREKEY_RECORD=1
        /// scripts/bench.sh`, the line «autoswitch, recording».
        public var batch = 256
        /// The most entries held at once, here and handed over but not
        /// written yet: 64 batches, a quarter hour of fast typing. 160 bytes an
        /// entry, about 2.6 MB in all (the test `theBufferStaysSmall` keeps
        /// it under 4 MB). Past it: `gap(overflow)`. A first estimate, not a
        /// measure: the overflow gaps in real recordings
        /// (`perekey-eval replay check`) tell whether the disk keeps up.
        public var limit = 16_384
        /// After an overflow the recording starts again once no more than this
        /// many entries are waiting: half the room, so it does not flap.
        public var resume = 8192

        public init() {}
    }

    /// One line of the file to be, in the form the tap thread has at hand.
    public enum Entry: Sendable {
        /// A segment starts. `newFile`: the recorder starts a file for it
        /// (the first segment of a launch, a new day, after erasing).
        /// Indirect: the snapshot is large and rare, and inline it would make
        /// every entry as large.
        indirect case snapshot(MachineSnapshot, Classifier?, newFile: Bool)
        case step(InputEvent, Output)
        case gap(SessionGap)
    }

    enum State: Equatable {
        /// The focus and Secure Input are not known yet: the first quiet
        /// point tells them.
        case starting
        case open
        case closed(SessionGap)
    }

    /// The password managers: nothing typed in them is recorded. The user
    /// adds apps of their own (`excludedApps`).
    public static let passwordManagers: Set<String> = [
        "com.1password.1password", // 1Password 8
        "com.agilebits.onepassword7", // 1Password 7
        "com.agilebits.onepassword-osx", // 1Password 6
        "com.bitwarden.desktop", // Bitwarden
        "org.keepassxc.keepassxc", // KeePassXC
        "com.apple.keychainaccess", // Keychain Access
        "com.apple.Passwords", // Passwords, macOS 15
    ]

    public let options: Options
    /// Apps never recorded: `passwordManagers` and the user's own.
    public var excludedApps: Set<String> {
        didSet { focusBlocks = Self.blocks(focus, excludedApps) }
    }

    private(set) var state = State.starting
    /// The entries not handed over yet.
    public private(set) var entries: [Entry] = []
    /// Entries handed to the recorder and not written yet (`written`).
    public private(set) var inFlight = 0
    /// The next snapshot starts a file.
    private var newFile = true
    private var focus: Focus?
    private var secureInput = false
    /// Why the focus alone keeps the recording off; worked out when the
    /// focus or the list changes, not on every key.
    private var focusBlocks: SessionGap?

    public init(options: Options = Options(), excludedApps: Set<String> = RecordingBuffer.passwordManagers) {
        self.options = options
        self.excludedApps = excludedApps
        entries.reserveCapacity(options.batch)
    }

    /// Why nothing may be recorded now, if anything.
    var blocked: SessionGap? {
        focusBlocks ?? (secureInput ? .secureInput : nil)
    }

    private static func blocks(_ focus: Focus?, _ excluded: Set<String>) -> SessionGap? {
        guard let focus else { return nil }
        if focus.isSecureField { return .secureField }
        if let app = focus.bundleID, excluded.contains(app) { return .excludedApp }
        return nil
    }

    /// What the machine just did: `event` and the `output` it answered.
    /// Call it right after `machine.handle(event)`, with that machine.
    /// Returns true when a batch is ready for `take()`.
    public mutating func record(_ event: InputEvent, _ output: Output, machine: borrowing InputMachine) -> Bool {
        switch event {
        case let .focusChanged(focus, _):
            self.focus = focus
            focusBlocks = Self.blocks(focus, excludedApps)
        case let .secureInputChanged(on):
            secureInput = on
        default:
            break
        }
        switch state {
        case .open:
            if let reason = blocked ?? (waiting + 1 >= options.limit ? .overflow : nil) {
                entries.append(.gap(reason))
                state = .closed(reason)
            } else {
                entries.append(.step(event, output))
                if newFile, machine.isQuiet { startSegment(machine.snapshot, machine.classifier) }
            }
        case .starting:
            guard machine.isQuiet, waiting < options.limit else { break }
            let snapshot = machine.snapshot
            focus = snapshot.focus
            focusBlocks = Self.blocks(snapshot.focus, excludedApps)
            secureInput = snapshot.secureInput
            if let reason = blocked {
                state = .closed(reason)
            } else {
                startSegment(snapshot, machine.classifier)
            }
        case let .closed(reason):
            let room = reason == .overflow ? options.resume : options.limit - 1
            guard blocked == nil, waiting <= room, machine.isQuiet else { break }
            startSegment(machine.snapshot, machine.classifier)
        }
        return entries.count >= options.batch
    }

    private mutating func startSegment(_ snapshot: MachineSnapshot, _ classifier: Classifier?) {
        entries.append(.snapshot(snapshot, classifier, newFile: newFile))
        newFile = false
        state = .open
    }

    /// Entries held here and handed over, not written yet.
    private var waiting: Int { entries.count + inFlight }

    /// Hands the entries over to the recorder; they count as in flight until
    /// `written`.
    public mutating func take() -> [Entry] {
        let batch = entries
        entries = []
        entries.reserveCapacity(options.batch)
        inFlight += batch.count
        return batch
    }

    /// The recorder wrote `count` entries. `newDay`: the day of its file is
    /// over, so the next segment goes to a file of its own; while the
    /// recording runs, the next quiet point starts one.
    public mutating func written(_ count: Int, newDay: Bool) {
        inFlight = max(0, inFlight - count)
        if newDay { newFile = true }
    }

    /// Starts over, as at the start of the recording: the files were erased.
    /// What was not handed over yet is dropped; the next segment starts a file.
    public mutating func restart() {
        entries.removeAll(keepingCapacity: true)
        state = .starting
        newFile = true
    }
}
#endif
