// SPDX-License-Identifier: GPL-3.0-or-later

/// What Perekey does about Accessibility access. Pure decisions; the callers
/// read `AXIsProcessTrusted` and the tap state.
public enum AccessPolicy {
    /// Where opening Perekey again (Finder, Spotlight) leads.
    public enum Reopen: Hashable, Sendable {
        case settings
        /// Onboarding from its first step: the user has not finished it.
        case onboarding
        /// The access step of onboarding: Settings would show a Perekey that does nothing.
        case onboardingAccess
    }

    public static func reopen(hasAccess: Bool, onboardingDone: Bool = true) -> Reopen {
        if !onboardingDone { return .onboarding }
        return hasAccess ? .settings : .onboardingAccess
    }

    /// Whether Settings shows the «no access» banner above its panes.
    public static func showsBanner(hasAccess: Bool) -> Bool { !hasAccess }

    /// Whether the taps must be dropped: they exist (running or suspended),
    /// and the system says no.
    public static func isRevoked(waitingForAccess: Bool, trusted: Bool) -> Bool {
        !waitingForAccess && !trusted
    }

    /// Checks after the system's access notification, in seconds. `AXIsProcessTrusted`
    /// lags behind the toggle, so one check right after it can still say «yes».
    public static let recheckDelays: [Double] = [0.4, 1.5, 4]

    /// The fallback check when no notification comes, in seconds.
    public static let pollInterval: Double = 5
}
