// SPDX-License-Identifier: GPL-3.0-or-later

#if PEREKEY_RECORD
import PerekeyCore

/// What the recording is doing now, for the badge in the menu bar (the
/// recording itself being on or off is the user's switch).
public enum TypingRecordingStatus: Sendable, Equatable {
    /// A segment is open: typing goes to the file.
    case recording
    /// The recording is on and writes nothing at the moment: it waits for a
    /// quiet point, for a known focus that is not a password, or for the disk
    /// to catch up.
    case waiting
    /// The last file could not be created or written. The recording tries a
    /// new file at a quiet point a little later.
    case failed
}

/// The tap thread's half of the typing recorder (CONTRIBUTING.md, «Recording
/// typing for the measure»): what the machine handled, kept in memory until
/// `SessionRecorder` takes it to disk on a queue of its own.
///
/// Only in a build with `PEREKEY_RECORD`. Per event the tap thread appends a
/// value to an array that has room for it: the event and the output as the
/// machine has them. Turning them into session lines (`RecordedEvent`,
/// `OutputDigest`), encoding and writing happen on the recorder's queue.
///
/// No memory per event; a snapshot at a segment start allocates (the copy of
/// the machine's state, rare, see below); one `queue.async` per batch. The
/// arrays are made once, when the buffer is: `Options.buffers` of them, each
/// with room for `Options.batch` entries and two more (a step may be followed
/// by the snapshot of a new segment). The array that is filling is handed over every
/// `Options.batch` entries or when the engine's timer asks (once a second),
/// another one from the spare ones takes its place, and the recorder gives the
/// used one back (`written`), empty and with its room. When none is spare and
/// the filling one is nearly full, the buffer ends the segment with
/// `gap(overflow)` instead of growing. Releasing the snapshots in an array
/// is the recorder's work too: it empties the array before giving it back.
///
/// A segment start copies the machine's state (`MachineSnapshot`); that
/// happens after a gap, at the start and once a day, not while typing goes on.
/// Until then the buffer asks the machine one cheap question only
/// (`InputMachine.isQuiet`, passed as a closure that reads the machine in
/// place): no copy of the machine, no snapshot.
///
/// What is never recorded: while the focus is a password field, while Secure
/// Input is on, while the focus is in an app of `excludedApps`, and while the
/// focus is not known (no event has named it, or accessibility did not say
/// what is focused, so it may be a password field), the buffer writes one
/// `gap` line and nothing more, not even the events that are not keys. The
/// segment ends there. A new one starts with a snapshot at the first quiet
/// point after the reason is gone, so a replay can start from it. The same
/// happens when the writer falls behind (`gap(overflow)`), and typing is never
/// slowed down. When the file cannot be written, the segment ends without a
/// line (`writeFailed`: there is no file to take one) and a new file starts a
/// little later.
public struct RecordingBuffer {
    public struct Options: Sendable {
        /// Entries handed to the recorder at once, as plan 6.3 asks. A key
        /// press and release are two events, so 256 entries are about 25
        /// words of typing; the engine's timer hands over a smaller batch
        /// after a second. The cost per event: `PEREKEY_RECORD=1
        /// scripts/bench.sh`, the line «autoswitch, recording».
        public var batch = 256
        /// Arrays of `batch` entries made when the buffer is, the filling one
        /// included. 16 of them hold 4096 entries, about 400 words, which a
        /// disk that is slow for a minute does not fill. The room: 160 bytes
        /// an entry, about 650 KB in all (the test `theBufferStaysSmall`
        /// keeps it under 4 MB). When all are in use: `gap(overflow)`. A
        /// first estimate, not a measure: the overflow gaps in real
        /// recordings (`perekey-eval replay check`) tell whether the disk
        /// keeps up.
        public var buffers = 16
        /// After an overflow the recording starts again once this many arrays
        /// are spare again: half of them, so it does not flap.
        public var resume = 8
        /// Events to let pass before a new file is tried after the last one
        /// could not be written: about 100 seconds of typing at 20 events a
        /// second (two per key). Not to ask a full disk for a file at every
        /// quiet point. A first estimate: `perekey-eval replay check` on a
        /// real recording shows the rate of events.
        public var retry = 2048

        public init() {}
    }

    /// One line of the file to be, in the form the tap thread has at hand.
    public enum Entry: Sendable {
        /// A segment starts. `newFile`: the recorder starts a file for it
        /// (the first segment of a launch, a new day, after erasing, after a
        /// failure). Indirect: the snapshot is large and rare, and inline it
        /// would make every entry as large.
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
    /// The entries not handed over yet: the array that is filling.
    public private(set) var entries: [Entry] = []
    /// Arrays that are empty and have room, ready to take the filling one's place.
    private var spare: [[Entry]] = []
    /// The next snapshot starts a file.
    private var newFile = true
    /// Events still to pass before a new file is tried after a failure.
    private var retryIn = 0
    private var focus: Focus?
    private var secureInput = false
    /// Why the focus alone keeps the recording off; worked out when the
    /// focus or the list changes, not on every key.
    private var focusBlocks: SessionGap?

    public init(options: Options = Options(), excludedApps: Set<String> = RecordingBuffer.passwordManagers) {
        self.options = options
        self.excludedApps = excludedApps
        entries.reserveCapacity(room)
        spare.reserveCapacity(options.buffers)
        for _ in 1..<max(1, options.buffers) {
            var array: [Entry] = []
            array.reserveCapacity(room)
            spare.append(array)
        }
        focusBlocks = Self.blocks(nil, excludedApps)
    }

    /// What the recording is doing now.
    public var status: TypingRecordingStatus {
        switch state {
        case .open: .recording
        case .starting: .waiting
        case let .closed(reason): reason == .writeFailed ? .failed : .waiting
        }
    }

    /// Arrays ready to take the place of the filling one (tests).
    var spareBuffers: Int { spare.count }

    /// Why nothing may be recorded now, if anything.
    var blocked: SessionGap? {
        focusBlocks ?? (secureInput ? .secureInput : nil)
    }

    private static func blocks(_ focus: Focus?, _ excluded: Set<String>) -> SessionGap? {
        guard let focus else { return .unknownFocus }
        if focus.isSecureField { return .secureField }
        if let app = focus.bundleID, excluded.contains(app) { return .excludedApp }
        return focus.isKnown ? nil : .unknownFocus
    }

    /// Entries an array holds without growing. A step that fills the array
    /// (`batch`) can be followed by the snapshot of a new file (`record`,
    /// `.open`): `batch + 1`; one more is left over.
    private var room: Int { options.batch + 2 }

    /// One more entry fits, and the array can leave when it is full.
    private var hasRoom: Bool {
        entries.count + 1 < options.batch || !spare.isEmpty
    }

    /// What the machine just did: `event` and the `output` it answered.
    /// Call it right after `machine.handle(event)`.
    ///
    /// `quiet` tells whether the machine is at a quiet point
    /// (`InputMachine.isQuiet`); it must read the machine in place, not a copy.
    /// `snapshot` gives its state and classifier; it is called only when a
    /// segment may start, so while the recording runs a step touches nothing
    /// of the machine. Returns true when a batch is ready for `take()`.
    public mutating func record(_ event: InputEvent, _ output: Output, quiet: () -> Bool,
                                snapshot: () -> (MachineSnapshot, Classifier?)) -> Bool
    {
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
            if let reason = blocked ?? (hasRoom ? nil : .overflow) {
                entries.append(.gap(reason))
                state = .closed(reason)
            } else {
                entries.append(.step(event, output))
                if newFile, hasRoom, quiet() {
                    let (machine, classifier) = snapshot()
                    startSegment(machine, classifier)
                }
            }
        case .starting:
            guard hasRoom, quiet() else { break }
            let (machine, classifier) = snapshot()
            focus = machine.focus
            focusBlocks = Self.blocks(focus, excludedApps)
            secureInput = machine.secureInput
            if let reason = blocked {
                state = .closed(reason)
            } else {
                startSegment(machine, classifier)
            }
        case let .closed(reason):
            switch reason {
            case .overflow:
                guard spare.count >= options.resume else { break }
            case .writeFailed:
                retryIn -= 1
                guard retryIn <= 0 else { break }
            default:
                break
            }
            guard blocked == nil, hasRoom, quiet() else { break }
            let (machine, classifier) = snapshot()
            startSegment(machine, classifier)
        }
        return entries.count >= options.batch
    }

    private mutating func startSegment(_ snapshot: MachineSnapshot, _ classifier: Classifier?) {
        entries.append(.snapshot(snapshot, classifier, newFile: newFile))
        newFile = false
        state = .open
    }

    /// Hands the filling array over and puts a spare one in its place.
    /// Nothing is made here. Empty when no array is spare: the entries then
    /// stay, and the buffer ends the segment before they overflow.
    public mutating func take() -> [Entry] {
        guard let next = spare.popLast() else { return [] }
        let batch = entries
        entries = next
        return batch
    }

    /// Everything not handed over yet, whatever the spare arrays: for the end
    /// of the recording, which may allocate.
    public mutating func takeAll() -> [Entry] {
        let batch = entries
        entries = []
        return batch
    }

    /// The recorder wrote a batch and gives its array back, empty. `newDay`:
    /// the day of its file is over, so the next segment goes to a file of its
    /// own; while the recording runs, the next quiet point starts one.
    /// `failed`: the file could not be created or written; the segment ends,
    /// and a new file is tried after `Options.retry` events.
    public mutating func written(_ returned: [Entry], newDay: Bool, failed: Bool = false) {
        var returned = returned
        if !returned.isEmpty { returned.removeAll(keepingCapacity: true) }
        if returned.capacity < room { returned.reserveCapacity(room) }
        if spare.count < options.buffers - 1 { spare.append(returned) }
        if newDay { newFile = true }
        if failed {
            newFile = true
            retryIn = options.retry
            if state == .open { state = .closed(.writeFailed) }
        }
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
