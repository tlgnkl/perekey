// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether and where Perekey introduces voice input to a person who has not
/// turned it on: once, never against their answer, never on a Mac that cannot
/// run it or under a profile that forbids it.
public enum VoiceIntro {
    public enum Offer: Hashable, Sendable {
        /// Nothing to show.
        case none
        /// Someone who already uses Perekey: the one window "What's new: voice input".
        case window
        /// Someone setting Perekey up: a step of the first-run window.
        case onboardingStep
    }

    public struct Situation: Hashable, Sendable {
        /// The first-run window was finished or closed before.
        public var onboardingDone: Bool
        /// The person answered the offer: turned voice on, or said "Not now".
        public var answered: Bool
        /// Voice is on already (turned on in the Voice tab, or in the file).
        public var voiceIsOn: Bool
        /// The Mac runs the models: Apple Silicon, macOS 15 or newer.
        public var isSupported: Bool
        /// A profile turns voice off (`VoiceDisabled`).
        public var disabledByProfile: Bool
        /// `voice.json` was written by a newer Perekey and is left alone.
        public var fileIsLocked: Bool
        /// Perekey has Accessibility: without it the keys do not reach it, and
        /// the access step of the first-run window comes first.
        public var hasAccess: Bool

        public init(onboardingDone: Bool, answered: Bool, voiceIsOn: Bool, isSupported: Bool,
                    disabledByProfile: Bool, fileIsLocked: Bool, hasAccess: Bool)
        {
            self.onboardingDone = onboardingDone
            self.answered = answered
            self.voiceIsOn = voiceIsOn
            self.isSupported = isSupported
            self.disabledByProfile = disabledByProfile
            self.fileIsLocked = fileIsLocked
            self.hasAccess = hasAccess
        }
    }

    public static func offer(_ situation: Situation) -> Offer {
        guard situation.isSupported, !situation.disabledByProfile, !situation.fileIsLocked,
              !situation.voiceIsOn, !situation.answered
        else { return .none }
        guard situation.onboardingDone else { return .onboardingStep }
        return situation.hasAccess ? .window : .none
    }
}
