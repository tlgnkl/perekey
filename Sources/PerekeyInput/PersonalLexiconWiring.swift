// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import PerekeyCore

/// How the app joins the personal lexicon store (`PersonalLexiconStore`) to
/// the rest: the setting «Мои слова» goes in, the snapshot for the tap comes
/// out, and the two moments when a Keychain that refused the key is asked
/// again (the app is activated, the screen is unlocked) call `retryActivation`.
/// The controller of the app only calls this type; every line of the joint is
/// here, where a test reaches it with a notification center of its own.
@MainActor
public final class PersonalLexiconWiring {
    /// The distributed notification the system posts when the screen is unlocked.
    public static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")
    /// Posted when the app is activated.
    public static let appActivated = NSApplication.didBecomeActiveNotification

    private let store: PersonalLexiconStore
    private var tokens: [(NotificationCenter, any NSObjectProtocol)] = []

    /// - Parameter send: gives the tap its snapshot (`InputEvent.personalLexiconChanged`).
    public init(store: PersonalLexiconStore, send: @escaping @MainActor (PersonalLexicon) -> Void) {
        self.store = store
        store.onLexiconChanged = send
    }

    /// The setting as the settings hold it; the store hears of a change only.
    public func settingsChanged(personalWords: Bool) {
        store.apply(personalWords)
    }

    /// The words the voice dictionary names as the user's own, whenever the
    /// dictionary changes: the store makes their fingerprints.
    public func sharedWordsChanged(_ words: [String]) {
        store.setSharedWords(words)
    }

    /// Listens for the app's activation on `application` and for the unlock on
    /// `distributed` (the system's notification center in the app; any in a test).
    /// Calling it again replaces the earlier listeners.
    public func observe(application: NotificationCenter = .default,
                        distributed: NotificationCenter = DistributedNotificationCenter.default())
    {
        stopObserving()
        for (center, name) in [(application, Self.appActivated), (distributed, Self.screenUnlocked)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.store.retryActivation() }
            }
            tokens.append((center, token))
        }
    }

    public func stopObserving() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }
}
