// SPDX-License-Identifier: GPL-3.0-or-later

/// Holds user input back while a retype is under way.
///
/// A layout switch reaches the application asynchronously, so keys typed
/// right after a retype could land in the old layout or between the
/// synthetic keys. After a retype `InputMachine` holds user keyboard input
/// until the tap has seen the last synthetic event and the system has
/// confirmed the layout change, or until `Settings.fenceTimeout` has passed.
/// Held events come back as `.replayed` and are handled as usual. A replayed
/// event can start a new retype; the replayed events after it are held
/// again, or they would overtake that retype.
///
/// Converting a selection raises the fence at once, before the text is
/// known: the system layer reads the selection (`Effect.convertSelection`),
/// answers with `.selectionRead`, and from there it goes like a word retype.
/// Keys the user types meanwhile are held the whole time.
///
/// Clicks cannot be held: the mouse tap only listens, since an active mouse
/// tap would delay all pointer input. A click during the fence reaches the
/// app before the held keys. The fence lasts milliseconds, so this is rare.
///
/// The fence also numbers the retypes and keeps the layout selections the
/// system has not confirmed yet.
struct Fence: Sendable {
    /// The retype the fence waits for.
    struct Hold: Sendable {
        var seq: UInt32
        var lastOwnEventSeen = false
        /// The layout whose selection the system has not confirmed yet.
        var awaitedLayout: LayoutID?
        var deadline: Double
        /// The layout to go back to if the retype is cancelled.
        var layoutBefore: LayoutID?
        /// The retype replaces the selection through accessibility: no own
        /// events will come, `.retypePosted` stands for the last one.
        var viaAccessibility = false
        var purpose: Purpose
    }

    /// What the retype is for, and so what to report once it is posted.
    enum Purpose: Sendable {
        /// Asked for by a shortcut: nothing to report.
        case retype
        /// The selection is being read; `.selectionRead` has not come yet.
        /// Then it is retyped as the action asks.
        case readingSelection(ManualActions.SelectionAction)
        /// An automatic correction: reported as `.corrected` once posted.
        case correction(CorrectionUndo.Pending)
        /// An undo of one: reported as `.correctionUndone` once posted.
        case undo(CorrectionUndo.InFlight)
    }

    /// The key that comes back first after the fence and belongs to the
    /// retype, not to the typing after it.
    enum Returning: Sendable, Equatable {
        case nothing
        /// The key that ended (or, inside a word, continued) a word an
        /// automatic correction retyped. It is neither judged again nor counts
        /// as typing after the correction.
        case boundary(keyCode: UInt16, endsWord: Bool)
        /// The Backspace that asked for an undo, which was posted: drop it.
        /// After a cancelled undo it comes back as an ordinary Backspace.
        case undoKey
    }

    private(set) var hold: Hold?
    private(set) var returning = Returning.nothing
    private var nextSeq: UInt32 = 1
    /// Layouts Perekey selected that the system has not confirmed yet, oldest
    /// first. A late confirmation of an earlier one must not undo a later one.
    private var pendingSelections: [LayoutID] = []
    /// The layout the system last reported as selected.
    private var confirmedLayout: LayoutID?

    init(confirmedLayout: LayoutID?) {
        self.confirmedLayout = confirmedLayout
    }

    var isHolding: Bool { hold != nil }

    mutating func takeSeq() -> UInt32 {
        let seq = nextSeq
        nextSeq = nextSeq == .max ? 1 : nextSeq + 1
        return seq
    }

    /// Perekey asked the system to select `id`.
    mutating func selected(_ id: LayoutID) {
        if pendingSelections.count == 8 { pendingSelections.removeFirst() }
        pendingSelections.append(id)
    }

    /// The system reports `id` as selected. False when someone else selected
    /// it: the user from the menu, or another app.
    mutating func confirmed(_ id: LayoutID, effects: inout [Effect]) -> Bool {
        confirmedLayout = id
        let ours: Bool
        if let index = pendingSelections.firstIndex(of: id) {
            pendingSelections.removeSubrange(...index)
            ours = true
        } else {
            pendingSelections.removeAll()
            ours = false
        }
        if hold?.awaitedLayout == id {
            hold?.awaitedLayout = nil
            releaseIfDone(effects: &effects)
        }
        return ours
    }

    /// Starts holding input for the retype `seq`. With a `target`, also waits
    /// until the system confirms that layout, unless it already has.
    mutating func raise(seq: UInt32, awaiting target: LayoutID?, layoutBefore: LayoutID? = nil, deadline: Double,
                        purpose: Purpose = .retype, effects: inout [Effect])
    {
        hold = Hold(seq: seq, awaitedLayout: target == confirmedLayout ? nil : target, deadline: deadline,
                    layoutBefore: layoutBefore, purpose: purpose)
        effects.append(.scheduleDeadline(at: deadline))
    }

    /// The selection for the retype `seq` arrived: what to do with it, or nil
    /// when the fence does not wait for it. The retype that follows reports
    /// nothing.
    mutating func selectionRead(seq: UInt32) -> ManualActions.SelectionAction? {
        guard hold?.seq == seq, case let .readingSelection(action) = hold?.purpose else { return nil }
        hold?.purpose = .retype
        return action
    }

    /// The selection is retyped into `target`.
    mutating func retypesSelection(into target: LayoutID, layoutBefore: LayoutID?, viaAccessibility: Bool) {
        hold?.awaitedLayout = target == confirmedLayout ? nil : target
        hold?.layoutBefore = layoutBefore
        hold?.viaAccessibility = viaAccessibility
    }

    /// The retype `seq` was posted: the fence now waits until `deadline` at
    /// most. Returns what it was for, once; nil when it is not the retype
    /// held for.
    mutating func posted(seq: UInt32, deadline: Double, effects: inout [Effect]) -> Purpose? {
        guard let posted = hold, posted.seq == seq else { return nil }
        if case .readingSelection = posted.purpose { return nil }
        hold?.deadline = deadline
        effects.append(.scheduleDeadline(at: deadline))
        hold?.purpose = .retype
        return posted.purpose
    }

    /// After `posted`: a retype through accessibility has no own events, so
    /// being posted is its last one.
    mutating func finishPosted(effects: inout [Effect]) {
        guard hold?.viaAccessibility == true else { return }
        hold?.lastOwnEventSeen = true
        releaseIfDone(effects: &effects)
    }

    /// A synthetic event of the retype `seq` came back through the tap.
    mutating func ownEvent(seq: UInt32, last: Bool, effects: inout [Effect]) {
        guard last, hold?.seq == seq else { return }
        hold?.lastOwnEventSeen = true
        releaseIfDone(effects: &effects)
    }

    /// A click outside the hint came while a correction is in flight: the
    /// caret may have moved, so it cannot be undone or extended.
    mutating func clickedDuringCorrection() {
        guard case var .correction(pending) = hold?.purpose else { return }
        pending.clicked = true
        hold?.purpose = .correction(pending)
    }

    /// A correction holds `key` for its retype.
    mutating func holdsBoundary(_ key: Returning) {
        returning = key
    }

    /// A key down by the user: the key a correction held, if it was waiting
    /// to come back. Only a replayed key with its key code is that key.
    mutating func takeBoundary(_ key: KeyEvent) -> (isHeldKey: Bool, endsWord: Bool)? {
        guard case let .boundary(keyCode, endsWord) = returning else { return nil }
        returning = .nothing
        return (key.keyCode == keyCode && key.origin == .replayed, endsWord)
    }

    /// Input was lost: no held key is coming back.
    mutating func forgetBoundary() {
        if case .boundary = returning { returning = .nothing }
    }

    /// An undo was posted. `heldKey`: the Backspace that asked for it was
    /// held and comes back first.
    mutating func undoPosted(heldKey: Bool) {
        if heldKey {
            returning = .undoKey
        } else if case .undoKey = returning {
            returning = .nothing
        }
    }

    /// A key after the fence: true when it is the Backspace of a posted undo,
    /// to be dropped. The held events come back in order, the Backspace first.
    mutating func takeUndoKey(_ key: KeyEvent) -> Bool {
        guard key.phase == .down, case .undoKey = returning else { return false }
        returning = .nothing
        return key.origin == .replayed && key.keyCode == KeyCode.delete
    }

    /// Lets input go once the deadline has passed. True when it did.
    @discardableResult
    mutating func expire(at time: Double, effects: inout [Effect]) -> Bool {
        guard let hold, time >= hold.deadline else { return false }
        release(effects: &effects)
        return true
    }

    mutating func release(effects: inout [Effect]) {
        guard hold != nil else { return }
        hold = nil
        effects.append(.releaseHeld)
    }

    private mutating func releaseIfDone(effects: inout [Effect]) {
        if let hold, hold.lastOwnEventSeen, hold.awaitedLayout == nil {
            if case .readingSelection = hold.purpose { return }
            release(effects: &effects)
        }
    }
}
