// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore

/// What `FocusObserver` publishes for each answer of the accessibility API,
/// apart from AX itself so it can be tested on plain values. `Element` is the
/// focused element; the observer compares AX elements with `CFEqual`.
///
/// After an app switch the focus is unknown until AX names the element. Keys
/// typed meanwhile went into that element, so the first element named is not
/// a new place (`FocusChange.resolved`), whether the read or a notification
/// names it. Electron apps often fail the read right after the switch: it is
/// tried again at `retryOffsets` until the focus is known. A notification
/// about the element published already is not a new place either; another
/// element is, even a field of the same kind. One exception: apps often name
/// a container first and the text view a few ms later. The first other
/// element of the same kind within `settleWindow` after the focus became known
/// is the same place, because the only keys the core holds were typed after the switch.
struct FocusTracker<Element: Equatable> {
    /// Seconds after the switch at which a read that gave no known focus is
    /// tried again. Only while the focus is unknown: no timers while idle.
    static var retryOffsets: [Double] { [0.05, 0.15, 0.4] }

    /// Seconds after the focus became known in which the first other element
    /// still counts as the same place. The number comes from the live
    /// measurement: the second element arrives 50–125 ms after the first.
    /// A change of the field's kind (password or not) is never absorbed.
    static var settleWindow: Double { 0.15 }

    struct Publication: Equatable {
        var focus: Focus
        var change: FocusChange
    }

    /// What the log should say about a step.
    enum Note: Equatable {
        /// The focus became known `seconds` after the switch. `reads` counts
        /// the reads so far, the one at the switch included.
        case known(seconds: Double, reads: Int, byNotification: Bool)
        /// A notification about the element published already: the word stays.
        case sameElement
        /// The last read gave no known focus: it waits for a notification.
        case gaveUp(reads: Int)
    }

    struct Step: Equatable {
        var publication: Publication?
        var note: Note?
    }

    private(set) var lastPublished: Focus?
    private var element: Element?
    /// When the app was switched to, while its focus is not known yet.
    private var switchedAt: Double?
    private var reads = 0
    /// When the focus became known after a switch, until the first other
    /// element is absorbed or the window ends.
    private var settlingSince: Double?
    /// The read in progress follows a switch, not a reread of the same app.
    private var afterSwitch = false

    /// The focus is not known since the last switch: a read may be tried again.
    var isWaiting: Bool { switchedAt != nil }

    /// The frontmost app changed (`switched`), or is read again from scratch.
    /// `focus` is unknown: no element is named yet.
    mutating func activated(_ focus: Focus, switched: Bool, at time: Double) -> Publication? {
        element = nil
        switchedAt = time
        settlingSince = nil
        afterSwitch = switched
        reads = 0
        return publish(focus, .moved, always: switched)
    }

    /// The same app is read again (`FocusObserver.refresh()`): the first
    /// other element after it is a new place, not the settling of a switch.
    mutating func refreshed() { settlingSince = nil }

    /// Accessibility stopped answering for good (the permission was revoked).
    mutating func lost(_ focus: Focus) -> Publication? {
        element = nil
        switchedAt = nil
        settlingSince = nil
        return publish(focus, .moved, always: false)
    }

    /// The read of the focused element named `element`, whose focus is `focus`.
    mutating func read(_ element: Element, focus: Focus, at time: Double) -> Step {
        reads += 1
        var step = found(element, focus, at: time, byNotification: false)
        if step.note == nil, isWaiting, retryDelay(at: time) == nil { step.note = .gaveUp(reads: reads) }
        return step
    }

    /// The read named no element.
    mutating func readFailed(at time: Double) -> Note? {
        reads += 1
        return isWaiting && retryDelay(at: time) == nil ? .gaveUp(reads: reads) : nil
    }

    /// The app reported `element` as focused.
    mutating func notified(_ element: Element, focus: Focus, at time: Double) -> Step {
        found(element, focus, at: time, byNotification: true)
    }

    /// Seconds until the next read, nil when there is none: the focus is
    /// known, or every retry is used.
    func retryDelay(at time: Double) -> Double? {
        guard let switchedAt, reads >= 1, reads <= Self.retryOffsets.count else { return nil }
        return max(0, switchedAt + Self.retryOffsets[reads - 1] - time)
    }

    private mutating func found(_ new: Element, _ focus: Focus, at time: Double, byNotification: Bool) -> Step {
        let first = element == nil
        var change: FocusChange = first || element == new ? .resolved : .moved
        // A change of the field's kind (password or not) is never the same place.
        if change == .moved, let since = settlingSince, time - since <= Self.settleWindow,
           focus.isSecureField == lastPublished?.isSecureField { change = .resolved }
        if element != new { settlingSince = nil }
        element = new
        var note: Note?
        if let switchedAt, focus.isKnown {
            note = .known(seconds: time - switchedAt, reads: reads, byNotification: byNotification)
            self.switchedAt = nil
            settlingSince = afterSwitch ? time : nil
        }
        let publication = publish(focus, change, always: change == .moved)
        if publication == nil, byNotification, !first { note = .sameElement }
        return Step(publication: publication, note: note)
    }

    private mutating func publish(_ focus: Focus, _ change: FocusChange, always: Bool) -> Publication? {
        guard always || focus != lastPublished else { return nil }
        lastPublished = focus
        return Publication(focus: focus, change: change)
    }
}
