// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PerekeyCore

/// How a pause reason looks and reads in the capsule and in the menu card.
/// Copy follows the pause reasons in `design/mockup.html`.
extension PauseReason {
    /// SF Symbol of the reason glyph.
    var symbol: String {
        switch self {
        case .timed: "pause.fill"
        case .secureInput: "lock.fill"
        case .passwordField: "key.fill"
        case .appOff: "nosign"
        }
    }

    /// Short text beside the glyph in the capsule.
    func capsuleText(now: Date) -> String {
        switch self {
        case let .timed(until): String(localized: "\(PauseSet.minutesLeft(until: until, at: now)) min")
        case let .secureInput(owner): owner.map { String($0.prefix(12)) } ?? String(localized: "secure")
        case .passwordField: String(localized: "password")
        case .appOff: String(localized: "off here")
        }
    }

    func title(now: Date) -> String {
        switch self {
        case let .timed(until): String(localized: "Paused for \(PauseSet.minutesLeft(until: until, at: now)) more min")
        case .secureInput: String(localized: "Paused: Secure Input")
        case .passwordField: String(localized: "Paused: password field")
        case let .appOff(app): String(localized: "Off in \(app)")
        }
    }

    var detail: String {
        switch self {
        case .timed: String(localized: "Perekey does not fix words or change the layout.")
        case let .secureInput(owner):
            if let owner {
                String(localized: "\(owner) turned on Secure Input. While it is on, macOS hides keystrokes from every app.")
            } else {
                String(localized: "An app turned on Secure Input. While it is on, macOS hides keystrokes from every app.")
            }
        case .passwordField: String(localized: "Perekey resumes when the cursor leaves the field.")
        case .appOff: String(localized: "The app modes say so. Perekey does not fix words or change the layout here.")
        }
    }

    /// The card's button, if the user can end this reason from the menu.
    var actionTitle: String? {
        switch self {
        case .timed: String(localized: "Resume")
        case .appOff: String(localized: "Turn on here")
        case .secureInput, .passwordField: nil
        }
    }
}
