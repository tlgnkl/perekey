// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether voice can take a file now: the switch and the system, not the queue.
public enum VoiceAvailability: Equatable, Sendable {
    case on
    /// The user's switch is off: Settings → Voice turns it on.
    case off
    /// This Mac, a profile or a newer settings file rules voice out: no switch helps.
    case unavailable
}

/// What to do with files Finder hands to the app. A cold launch calls
/// `application(_:open:)` before the queue exists, so a file waits for it
/// (`hold`) and is refused, with a reason, when the wait ends.
public enum FileOpenDecision: Equatable, Sendable {
    case enqueue
    case hold
    case refuse(Refusal)

    public enum Refusal: Equatable, Sendable {
        case notMedia
        case voiceOff
        case voiceUnavailable
        /// Voice is on, but the queue did not come up in time.
        case notReady

        /// Whether turning voice on in Settings can change the outcome.
        public var settingsCanHelp: Bool { self == .voiceOff }
    }

    /// How long a file waits for the queue.
    public static let holdLimit: Duration = .seconds(15)

    public static func decide(hasMedia: Bool, voice: VoiceAvailability, queueReady: Bool, waitedTooLong: Bool = false) -> FileOpenDecision {
        guard hasMedia else { return .refuse(.notMedia) }
        switch voice {
        case .off: return .refuse(.voiceOff)
        case .unavailable: return .refuse(.voiceUnavailable)
        case .on: break
        }
        if queueReady { return .enqueue }
        return waitedTooLong ? .refuse(.notReady) : .hold
    }
}
