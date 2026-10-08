// SPDX-License-Identifier: GPL-3.0-or-later

import PerekeyCore
import PerekeyInput

/// Feeds the system's reasons to hold back into the capsule: Secure Input and
/// a focused password field. App modes come with stage 2.
///
/// Without Accessibility access the focus observer stays silent, and the
/// password-field reason never shows; Secure Input works without it.
@MainActor
final class PauseSources {
    private let secureInput = SecureInputMonitor()
    private let focus: FocusObserver

    init(pause: PauseState) {
        focus = FocusObserver { focus in
            // Called on the accessibility thread.
            Task { @MainActor in pause.setPasswordField(focus.isKnown && focus.isSecureField) }
        }
        secureInput.onChange = { [secureInput] isOn in
            pause.setSecureInput(isOn, owner: secureInput.ownerName)
        }
        pause.setSecureInput(secureInput.isOn, owner: secureInput.ownerName)
        focus.start()
    }
}
